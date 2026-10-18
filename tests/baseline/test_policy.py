"""The regression policy this repository ships, audited against the rest of it.

Every assertion here is a cross-artifact one: the policy is checked against the
tool that reads it, the ladder the figures are bucketed on, the queries that
produce the labels, and the scenarios the selectors name. That is deliberate.
Each of those is a separate file, each can be edited alone, and the failure
mode when they drift apart is not an error - it is an UNMATCHED selector or an
allowance too narrow for the ladder to resolve, which this project treats as a
failure precisely because nothing else would notice.

The one assertion that is not a cross-check is on the failure directions. A
policy that admits an unresolved verdict as a pass silently admits every change
too small for the ladder to see, which is most of them.
"""

from __future__ import annotations

import re
import unittest

from _support import LADDER, REPO_ROOT, capture, committed_policy, compare, measurement

POLICY = committed_policy()
GATES = POLICY["gates"]
DEFAULTS = POLICY["defaults"]

# Labels the percentile query can actually emit. Read from the query rather
# than listed here, because a gate naming a label the query never produces is
# a gate that reports unmatched forever.
QUANTILE_SOURCE = (REPO_ROOT / "queries" / "latency-percentiles.sql").read_text(encoding="utf-8")
PRODUCED_LABELS = {
    f"p{int(float(quantile) * 100)}"
    for quantile in re.findall(r"\(\s*(0\.[0-9]+)\s*\)", QUANTILE_SOURCE)
}

STAGES_SOURCE = (REPO_ROOT / "scenarios" / "lib" / "stages.js").read_text(encoding="utf-8")
PROFILE_PHASES = set(re.findall(r"phase:\s*'([a-z]+)'", STAGES_SOURCE))

SCENARIO_DIRECTORY = REPO_ROOT / "scenarios"


def percentile_rules(gate: dict) -> dict:
    return (gate.get("rules") or {}).get("percentile") or {}


class PolicyShape(unittest.TestCase):
    def test_the_policy_is_the_version_the_tool_reads(self) -> None:
        self.assertEqual(POLICY["schema_version"], compare.SUPPORTED_SCHEMA)

    def test_the_policy_declares_gates_with_distinct_names(self) -> None:
        ids = [gate.get("id") for gate in GATES]
        self.assertTrue(all(ids), "a gate with no id cannot be referred to in a report")
        self.assertEqual(len(ids), len(set(ids)))

    def test_every_gate_explains_what_it_is_for(self) -> None:
        # The allowances differ between gates by an order of magnitude, and an
        # unexplained difference reads as an accident and gets copied.
        for gate in GATES:
            self.assertTrue(str(gate.get("about") or "").strip(), gate.get("id"))

    def test_every_gate_checks_something(self) -> None:
        # A gate that declares no rules checks nothing and would pass.
        for gate in GATES:
            self.assertTrue(gate.get("rules"), gate.get("id"))


class Selectors(unittest.TestCase):
    def test_every_selector_names_a_scenario_and_a_phase(self) -> None:
        for gate in GATES:
            select = gate.get("select") or {}
            self.assertIn("scenario", select, gate["id"])
            self.assertIn("phase", select, gate["id"])

    def test_every_selector_names_a_scenario_this_repository_ships(self) -> None:
        # A selector that matches nothing is a FAILURE here rather than a
        # pass, so a renamed scenario surfaces as a broken gate - but it
        # surfaces at verdict time, after a run has been paid for.
        for gate in GATES:
            scenario = compare.scenario_id(gate["select"]["scenario"])
            self.assertTrue(
                (SCENARIO_DIRECTORY / f"{scenario}.js").is_file(),
                f"gate {gate['id']} selects {scenario}, which is not a committed scenario",
            )

    def test_every_committed_scenario_is_governed_by_a_gate(self) -> None:
        # The other direction: a scenario with no gate can be run, measured
        # and compared, and the comparison reports that no gate applied.
        governed = {compare.scenario_id(gate["select"]["scenario"]) for gate in GATES}
        shipped = {path.stem for path in SCENARIO_DIRECTORY.glob("*.js")}
        self.assertEqual(shipped - governed, set(), "these scenarios have no regression gate")

    def test_every_selected_phase_is_one_the_profiles_actually_emit(self) -> None:
        self.assertIn("steady", PROFILE_PHASES, "the profile library emits no steady phase")
        for gate in GATES:
            phase = str(gate["select"]["phase"])
            self.assertIn(
                phase,
                PROFILE_PHASES,
                f"gate {gate['id']} selects phase {phase}, which no profile tags a request with",
            )

    def test_the_gates_judge_the_held_state_rather_than_the_ramp(self) -> None:
        # The ramp phases exist to reach the steady state, and their latency
        # is a property of the ramp shape rather than of the change under test.
        for gate in GATES:
            self.assertEqual(gate["select"]["phase"], "steady", gate["id"])


class RuleVocabulary(unittest.TestCase):
    def test_every_percentile_label_is_one_the_query_produces(self) -> None:
        self.assertTrue(PRODUCED_LABELS, "no quantiles were readable from the percentile query")
        for gate in GATES:
            for label in percentile_rules(gate):
                self.assertIn(label, PRODUCED_LABELS, f"gate {gate['id']} names {label}")

    def test_every_allowance_is_one_the_tool_can_combine(self) -> None:
        # `allowance` refuses an unknown combination, so running it over every
        # rule is the vocabulary check.
        for gate in GATES:
            for label, rule in percentile_rules(gate).items():
                computed = compare.allowance(rule, 250.0, absolute_key="allow_abs_ms")
                self.assertGreater(computed, 0.0, f"{gate['id']}/{label} permits nothing at all")
            for field in ("error_rate_pct", "achieved_rate_per_s", "dropped_iterations", "mean_ms"):
                rule = (gate.get("rules") or {}).get(field)
                if rule and "max_abs" not in rule:
                    compare.allowance(rule, 1.0, absolute_key="allow_abs")

    def test_an_error_rate_is_bounded_absolutely_and_never_relatively(self) -> None:
        # A relative allowance on an error rate is meaningless at the bottom
        # of the range, where the baseline is zero and every multiple of it is
        # also zero.
        for gate in GATES:
            rule = (gate.get("rules") or {}).get("error_rate_pct")
            if rule is None:
                continue
            self.assertIn("allow_abs", rule, gate["id"])
            self.assertNotIn("allow_rel_pct", rule, gate["id"])

    def test_the_throughput_gate_is_bounded_from_below(self) -> None:
        # The one figure where lower is worse: a change that holds its latency
        # by serving less is a regression, and a gate reading only latency
        # passes it.
        for gate in GATES:
            rule = (gate.get("rules") or {}).get("achieved_rate_per_s")
            if rule is None:
                continue
            self.assertEqual(rule.get("direction"), "not_below", gate["id"])

    def test_dropped_iterations_are_a_hard_count_in_every_gate(self) -> None:
        # Not an allowance against the baseline: a run that dropped iterations
        # did not offer the rate it reports, so its latency figures describe a
        # smaller run than the one named.
        for gate in GATES:
            rule = (gate.get("rules") or {}).get("dropped_iterations")
            self.assertIsNotNone(rule, f"gate {gate['id']} does not check dropped iterations")
            self.assertEqual(rule.get("max_abs"), 0, gate["id"])
            self.assertNotIn("allow_rel_pct", rule, gate["id"])


class FailureDirections(unittest.TestCase):
    def test_an_unresolved_verdict_and_an_unmatched_selector_both_fail(self) -> None:
        self.assertEqual(DEFAULTS.get("on_unresolved"), "fail")
        self.assertEqual(DEFAULTS.get("on_unmatched_selector"), "fail")

    def test_the_comparability_checks_are_all_on(self) -> None:
        for flag in ("require_comparable", "require_same_ladder", "require_same_scenario"):
            self.assertIs(DEFAULTS.get(flag), True, flag)

    def test_the_observation_floors_match_the_ones_a_baseline_is_blessed_under(self) -> None:
        # Two files decide what counts as enough data - the capture tool, when
        # it blesses a baseline, and the policy, at verdict time. If they
        # disagree, a baseline can be admitted that every later comparison
        # then refuses to judge against.
        self.assertEqual(DEFAULTS.get("min_windows"), capture.BASELINE_MIN_WINDOWS)
        self.assertEqual(
            DEFAULTS.get("min_latency_observations"), capture.BASELINE_MIN_OBSERVATIONS
        )

    def test_the_offered_rate_tolerance_is_tight_enough_to_mean_something(self) -> None:
        # Latency is a function of offered load, so a loose tolerance here
        # turns every comparison into one between two load levels.
        tolerance = float(DEFAULTS.get("offered_rate_tolerance_pct"))
        self.assertGreater(tolerance, 0.0)
        self.assertLessEqual(tolerance, 5.0)


class AllowanceWidths(unittest.TestCase):
    def test_an_allowance_widens_with_the_percentile(self) -> None:
        # The ladder's spacing widens with the figure: a p50 in the tens of
        # milliseconds sits among 5ms boundaries while a p99 in the hundreds
        # sits among 50ms ones, so a p99 allowance of 10ms could never be
        # resolved.
        for gate in GATES:
            rules = percentile_rules(gate)
            ordered = sorted(rules, key=lambda label: int(label[1:]))
            widths = [float(rules[label]["allow_abs_ms"]) for label in ordered]
            self.assertEqual(widths, sorted(widths), f"{gate['id']}: {ordered}")

    def test_the_write_path_is_allowed_more_than_the_read_path(self) -> None:
        # Its own variance is larger, so a gate copied from the read path
        # would fail on it regularly and be ignored.
        read = percentile_rules(self.gate("read-steady"))
        write = percentile_rules(self.gate("write-steady"))
        for label in sorted(set(read) & set(write)):
            self.assertGreaterEqual(
                float(write[label]["allow_abs_ms"]), float(read[label]["allow_abs_ms"]), label
            )

    def test_the_journey_is_allowed_the_most_of_all(self) -> None:
        # Its percentiles are over a sequence, so they carry every step's
        # variance.
        journey = percentile_rules(self.gate("journey-steady"))
        write = percentile_rules(self.gate("write-steady"))
        for label in sorted(set(journey) & set(write)):
            self.assertGreaterEqual(
                float(journey[label]["allow_abs_ms"]), float(write[label]["allow_abs_ms"]), label
            )

    def gate(self, gate_id: str) -> dict:
        return next(gate for gate in GATES if gate["id"] == gate_id)


class LadderResolution(unittest.TestCase):
    """What the policy's own numbers can and cannot resolve on this ladder."""

    def ceilings(self, rule: dict) -> list[tuple[float, float]]:
        """Every (baseline boundary, ceiling) pair this rule implies."""
        pairs = []
        for boundary in LADDER:
            allowed = compare.allowance(rule, boundary, absolute_key="allow_abs_ms")
            pairs.append((boundary, boundary + allowed))
        return pairs

    def test_a_ceiling_that_lands_on_a_boundary_always_resolves(self) -> None:
        # The committed read-path p95 gate is one of these: a 250ms baseline
        # with a 50ms allowance puts the ceiling at 300ms, which is a
        # boundary, so no candidate bucket can straddle it.
        rule = next(
            percentile_rules(gate)["p95"] for gate in GATES if gate["id"] == "read-steady"
        )
        self.assertEqual(compare.allowance(rule, 250.0, absolute_key="allow_abs_ms"), 50.0)
        self.assertIn(300.0, LADDER)

    def test_the_unresolved_verdict_is_reachable_on_this_ladder(self) -> None:
        # Which is why `on_unresolved` is load-bearing rather than
        # decorative: for most baselines the ceiling falls inside a bucket,
        # and no tightening of the allowance changes that - only a new
        # boundary does.
        boundaries = set(LADDER)
        reachable = [
            (gate["id"], label, baseline, ceiling)
            for gate in GATES
            for label, rule in percentile_rules(gate).items()
            for baseline, ceiling in self.ceilings(rule)
            if ceiling not in boundaries
        ]
        self.assertTrue(
            reachable,
            "no gate can ever report unresolved, which would make on_unresolved meaningless",
        )
        self.assertEqual(DEFAULTS.get("on_unresolved"), "fail")

    def test_every_allowance_is_at_least_the_smallest_boundary_step(self) -> None:
        # An allowance below the finest spacing on the ladder cannot be
        # resolved anywhere, which makes the gate silent rather than strict.
        finest = min(
            later - earlier for earlier, later in zip(LADDER, LADDER[1:])
        )
        for gate in GATES:
            for label, rule in percentile_rules(gate).items():
                self.assertGreaterEqual(
                    float(rule["allow_abs_ms"]), finest, f"{gate['id']}/{label}"
                )


class AgainstRealMeasurements(unittest.TestCase):
    """The committed policy run end to end over documents it has to judge."""

    def judged(self, scenario: str, **candidate_kwargs) -> dict:
        overrides = {"scenario": f"scenarios/{scenario}.js"}
        baseline = measurement(index_overrides=overrides)
        candidate = measurement(role="candidate", index_overrides=overrides, **candidate_kwargs)
        return compare.compare(baseline=baseline, candidate=candidate, policy=POLICY)

    def test_each_scenario_is_judged_by_exactly_one_gate(self) -> None:
        for scenario in ("http-read", "http-write", "user-journey"):
            report = self.judged(scenario)
            applicable = [
                gate for gate in report["gates"] if gate["verdict"] != compare.SKIPPED
            ]
            self.assertEqual(len(applicable), 1, scenario)
            self.assertEqual(report["outcome"], "pass", scenario)

    def test_an_unchanged_run_passes_every_gate_that_applies(self) -> None:
        report = self.judged("http-read")
        gate = next(g for g in report["gates"] if g["verdict"] != compare.SKIPPED)
        self.assertEqual(gate["id"], "read-steady")
        self.assertEqual(gate["verdict"], compare.PASS)

    def test_a_slower_run_is_caught_by_the_percentile_rule(self) -> None:
        report = self.judged("http-read", percentiles={"p50": 50.0, "p95": 650.0, "p99": 800.0})
        self.assertEqual(report["outcome"], "regressed")

    def test_a_run_that_holds_its_latency_by_serving_less_is_caught(self) -> None:
        report = self.judged("http-read", summary_overrides={"achieved_rate_per_s": 600.0})
        self.assertEqual(report["outcome"], "regressed")

    def test_a_run_that_dropped_iterations_is_caught_even_when_it_looks_better(self) -> None:
        report = self.judged(
            "http-read",
            summary_overrides={"dropped_iterations": 12},
            percentiles={"p50": 30.0, "p95": 100.0, "p99": 150.0},
        )
        self.assertEqual(report["outcome"], "regressed")

    def test_a_scenario_with_no_measurement_of_its_own_is_not_reported_as_passing(self) -> None:
        overrides = {"scenario": "scenarios/http-read.js"}
        baseline = measurement(index_overrides=overrides)
        candidate = measurement(role="candidate", index_overrides=overrides, phase="recovery")
        report = compare.compare(baseline=baseline, candidate=candidate, policy=POLICY)
        self.assertEqual(report["outcome"], "unmatched")
        self.assertEqual(
            compare.exit_code(report, DEFAULTS), compare.EXIT_NOT_JUDGED
        )


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
