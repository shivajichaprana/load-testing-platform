# ---------------------------------------------------------------------------
# The pipeline, as targets.
#
# Every gate the CI workflow runs is reachable from here with the same
# invocation, so a check cannot pass locally and fail in the pipeline because
# the two were written separately. Where a tool reads a committed
# configuration - flake8, yamllint, tflint - neither side passes limits on the
# command line, for the same reason.
#
# Nothing here applies anything to a real account. `run` prints a plan and
# exits unless EXECUTE=1 is passed, which is the launcher's own default rather
# than a convention added on top of it.
# ---------------------------------------------------------------------------

SHELL       := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

PYTHON    ?= python3
NODE      ?= node
TERRAFORM ?= terraform
TFLINT    ?= tflint

# Build outputs, ignored by version control. A measurement document meant for
# review is written under baseline/profiles/ instead, by `capture OUT=...`.
BUILD ?= build

# Where a run's query output is read from by `capture` and `report`: four
# files, each named for the query that produced it.
RESULTS ?= $(BUILD)/results

# The three queries that decide whether the rest of a run's numbers mean
# anything, in the order they have to be read. A placement shortfall, a silent
# worker or a reclaimed one makes every latency figure in the run a figure
# about a different experiment, and no precision further down repairs that.
DECISIVE_QUERIES := run-index offered-vs-achieved worker-skew

# The four files `capture` needs, in the order the tool takes them.
MEASUREMENT_INPUTS := index summary percentiles contract

# A missing required variable is a usage error and should name itself rather
# than surface as a tool complaining about an empty argument. The message
# cannot contain a comma: make would read it as a further argument.
define require
$(if $(strip $($(1))),,$(error $(1) is required - $(2)))
endef

.DEFAULT_GOAL := help
.PHONY: help size fmt fmt-check validate test test-scenarios test-baseline \
        lint lint-imports run index capture compare report ci clean

help: ## Show this help
	@printf 'Targets:\n'
	@grep -hE '^[a-z][a-z-]*:.*## ' $(MAKEFILE_LIST) | sort \
	  | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'
	@printf '\nSizing needs no state and no credentials:  make size\n'
	@printf 'Launching prints a plan unless asked:      make run EXECUTE=1 ...\n'

# ---------------------------------------------------------------------------
# Sizing and configuration
# ---------------------------------------------------------------------------

size: ## Print the derived fleet, both per-worker bounds, and the findings
	@for output in fleet_plan fleet_bounds worker_socket_budget fleet_findings; do \
	  printf '\n== %s ==\n' "$$output"; \
	  $(TERRAFORM) output "$$output"; \
	done

fmt: ## Rewrite Terraform files to canonical form
	$(TERRAFORM) fmt -recursive

fmt-check: ## Fail if any Terraform file is not in canonical form
	$(TERRAFORM) fmt -check -recursive -diff

validate: fmt-check ## Initialize without a backend then validate and lint the configuration
	$(TERRAFORM) init -backend=false -input=false
	$(TERRAFORM) validate
	$(TFLINT) --init
	$(TFLINT) --format compact

# ---------------------------------------------------------------------------
# Tests and lint
#
# Two runners because there are two languages and neither wraps the other. The
# scenario library is plain modules executed by the generator's own runtime;
# the baseline tools are standalone scripts. Neither suite needs anything
# installed: the generator's built-in modules are substituted by a resolver
# hook, and the Python suite uses the standard library's runner.
# ---------------------------------------------------------------------------

test: ## Run both suites
	./tests/run.sh

test-scenarios: ## Run the scenario library and entrypoint suites
	$(NODE) --import ./tests/scenarios/support/register.mjs --test tests/scenarios/*.test.mjs

test-baseline: ## Run the capture comparison and policy suites
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover \
	  --start-directory tests/baseline --top-level-directory tests/baseline --verbose

lint: lint-imports ## Lint Python and YAML as well as scenario imports
	$(PYTHON) -m pyflakes $$(git ls-files '*.py')
	$(PYTHON) -m flake8 $$(git ls-files '*.py')
	$(PYTHON) -m yamllint --strict $$(git ls-files '*.yaml' '*.yml')

lint-imports: ## Fail if a scenario imports a module the generator cannot resolve
	@specifiers=$$(grep -rhoP "from '[^']+'" --include='*.js' scenarios/ | sort -u); \
	foreign=$$(echo "$$specifiers" | grep -vP "^from '(k6(/[a-z]+)?|\.{1,2}/[^']+)'$$" || true); \
	if [ -n "$$foreign" ]; then \
	  echo "a scenario imports a module the generator cannot resolve:" >&2; \
	  echo "$$foreign" >&2; \
	  exit 1; \
	fi; \
	echo "$$specifiers" | wc -l | xargs printf '%s import specifier(s) - all resolvable\n'

# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

run: ## Launch the fleet - prints a plan and exits unless EXECUTE=1. Needs SUBNET and TARGET_RATE
	$(call require,SUBNET,a runner subnet id; repeat inside the value for several)
	$(call require,TARGET_RATE,the rate to offer in requests per second)
	@mkdir -p $(BUILD)
	cluster="$${CLUSTER:-$$($(TERRAFORM) output -raw cluster_name)}"; \
	task_definition="$${TASK_DEFINITION:-$$($(TERRAFORM) output -raw task_definition_arn)}"; \
	security_group="$${SECURITY_GROUP:-$$($(TERRAFORM) output -raw runner_security_group_id)}"; \
	workers="$${WORKERS:-$$($(TERRAFORM) output -json fleet_plan | $(PYTHON) -c 'import json, sys; print(json.load(sys.stdin)["worker_count"])')}"; \
	subnets=""; for subnet in $(SUBNET); do subnets="$$subnets --subnet $$subnet"; done; \
	$(PYTHON) tools/launch-fleet.py \
	  --cluster "$$cluster" \
	  --task-definition "$$task_definition" \
	  --security-group "$$security_group" \
	  --workers "$$workers" \
	  --target-rate '$(TARGET_RATE)' \
	  $$subnets \
	  $(if $(LOAD_MODEL),--load-model $(LOAD_MODEL),) \
	  $(if $(PUBLIC_IP),--assign-public-ip,) \
	  $(if $(RUN_ID),--run-id $(RUN_ID),) \
	  $(if $(EXECUTE),--execute,) \
	  --json | tee $(BUILD)/launch-report.json
	@printf '\nlauncher report: %s\n' '$(BUILD)/launch-report.json'
	@$(if $(EXECUTE),printf 'Record the run with: make index SCENARIO=<file>\n',printf 'Nothing was sent. Add EXECUTE=1 to launch.\n')

index: ## Publish the launcher report as the run's row in the run index. Needs SCENARIO
	$(call require,SCENARIO,the scenario file the fleet was launched with)
	@test -f $(BUILD)/launch-report.json \
	  || { echo 'no launcher report yet - run make run first' >&2; exit 1; }
	parameter="$$($(TERRAFORM) output -json result_contract_parameter | $(PYTHON) -c 'import json, sys; print(json.load(sys.stdin)["name"])')"; \
	$(PYTHON) tools/publish-run-index.py \
	  --report $(BUILD)/launch-report.json \
	  --contract-parameter "$$parameter" \
	  --cluster "$$($(TERRAFORM) output -raw cluster_name)" \
	  --task-definition "$$($(TERRAFORM) output -raw task_definition_arn)" \
	  --scenario '$(SCENARIO)' \
	  $(if $(EXECUTE),--execute,)

# ---------------------------------------------------------------------------
# Measuring and comparing
#
# A measurement document is the figures together with the conditions under
# which those figures mean anything. The conditions travel inside it because a
# condition supplied separately from the figures is one that can be supplied
# wrongly.
# ---------------------------------------------------------------------------

ROLE      ?= candidate
OUT       ?= $(BUILD)/$(ROLE).json
# The blessed document a candidate is judged against. It lives in version
# control, because a baseline nobody reviewed is a figure nobody agreed to be
# held to.
BASELINE  ?= baseline/profiles/http-read.json
CANDIDATE ?= $(BUILD)/candidate.json

capture: ## Build a measurement document from a run's query output. ROLE=candidate|baseline
	@for required in $(MEASUREMENT_INPUTS); do \
	  test -f "$(RESULTS)/$$required.json" \
	    || { echo "missing $(RESULTS)/$$required.json - make report lists what produces it" >&2; exit 1; }; \
	done
	@mkdir -p $(dir $(OUT))
	$(PYTHON) baseline/capture.py \
	  --role $(ROLE) \
	  --index-row $(RESULTS)/index.json \
	  --summary $(RESULTS)/summary.json \
	  --percentiles $(RESULTS)/percentiles.json \
	  --contract $(RESULTS)/contract.json \
	  --out $(OUT)
	@printf 'measurement document: %s\n' '$(OUT)'

compare: ## Judge a candidate against a baseline. 0 pass 1 regressed 2 unresolved 3 void
	@test -f $(BASELINE)  || { echo 'no baseline at $(BASELINE)' >&2; exit 4; }
	@test -f $(CANDIDATE) || { echo 'no candidate at $(CANDIDATE) - run make capture first' >&2; exit 4; }
	@mkdir -p $(BUILD)
	$(PYTHON) baseline/compare.py \
	  --baseline $(BASELINE) \
	  --candidate $(CANDIDATE) \
	  --thresholds baseline/thresholds.yaml \
	  --format $(if $(JSON),json,text) \
	  --out $(BUILD)/comparison.$(if $(JSON),json,txt)

report: ## Read a run - the catalogue in order then the conditions. Needs RUN_ID
	$(call require,RUN_ID,the run to read)
	@printf '== the catalogue - in the order it has to be read ==\n\n'
	@printf 'Parameters are positional: run_id, dt_from, dt_to. The dates are\n'
	@printf 'inclusive UTC calendar dates and they prune partitions rather than\n'
	@printf 'filter rows, so a run crossing midnight writes into two of them.\n\n'
	@printf 'These three decide whether the rest of the numbers mean anything:\n'
	@for name in $(DECISIVE_QUERIES); do \
	  printf '  %-26s %s\n' "$$name.sql" "$$(head -1 queries/$$name.sql | sed 's/^-- *//')"; \
	done
	@printf '\nThen, once the run is known to be sound:\n'
	@for path in queries/*.sql; do \
	  name=$$(basename "$$path" .sql); \
	  case ' $(DECISIVE_QUERIES) ' in *" $$name "*) continue ;; esac; \
	  printf '  %-26s %s\n' "$$name.sql" "$$(head -1 "$$path" | sed 's/^-- *//')"; \
	done
	@printf '\nrun_id = %s\n' '$(RUN_ID)'
	@printf 'The same text is registered as named queries in the fleet workgroup:\n'
	@printf '  terraform output result_catalog\n'
	@missing=0; for required in $(MEASUREMENT_INPUTS); do \
	  test -f "$(RESULTS)/$$required.json" || missing=1; \
	done; \
	if [ "$$missing" -ne 0 ]; then \
	  printf '\nNo query output under %s yet, so there are no conditions to report.\n' '$(RESULTS)'; \
	  printf 'Write the output of each query there as %s.json.\n' '{index,summary,percentiles,contract}'; \
	  exit 0; \
	fi; \
	printf '\n== the conditions this run was measured under ==\n\n'; \
	$(MAKE) --no-print-directory capture ROLE=candidate OUT=$(BUILD)/report-document.json >/dev/null; \
	$(PYTHON) -c 'import json, sys; d = json.load(open(sys.argv[1])); rows = list(d["run"].items()) + [("", "")] + [(k, v) for k, v in d["conditions"].items() if k != "ladder_boundaries_ms"]; print("\n".join("  {:<26} {}".format(k, v) for k, v in rows))' $(BUILD)/report-document.json; \
	printf '\nA difference in any of those from the baseline voids a comparison\n'; \
	printf 'rather than failing it: the run measured something else.\n'

# ---------------------------------------------------------------------------
# Everything the pipeline runs
# ---------------------------------------------------------------------------

ci: test-scenarios lint-imports test-baseline lint validate ## Run every gate the pipeline runs
	@printf '\nevery gate passed\n'

clean: ## Remove build outputs
	rm -rf $(BUILD)
