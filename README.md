# load-testing-platform

Distributed load testing on AWS: Fargate runner fleet, test-as-code, baselines,
CI regression gates.

A load test is an experiment, and most load testing infrastructure is built in a
way that quietly invalidates it. This repository is organised around the places
that happens: the fleet is sized from the objective rather than guessed at, the
properties that decide what a run can measure are computed and published rather
than left implicit, and anything that makes two runs incomparable is reported
with the figure it rests on.

## What it does

- **Derives the fleet from the load objective.** You state a request rate and
  the response-time ceiling you are still willing to measure. The number of
  workers, the processor and socket ceilings behind it, and which of the two is
  binding all come out of `terraform output`.
- **Runs generators as a per-run fleet on serverless containers**, with a
  synchronized start instant so the ramp is the profile's and not the
  scheduler's.
- **Separates the permissions the platform needs from the ones the generator
  needs**, so that a scenario cannot reach anything the run does not require.
- **Reports what the configuration costs the experiment**, including the
  measurement consequences of the network path and of interruptible capacity.
- **Keeps a queryable run history.** Workers stream their measurements during
  the run, catalogued and partitioned so that reading one run touches one
  prefix, with a committed query catalogue over it and two dashboards that
  keep what the target did apart from what the generator did.

## Sizing: the part that is usually wrong

### Throughput is an input or an output, never both

A generator either produces arrivals at a fixed rate regardless of what comes
back (the open model), or maintains a fixed population of users that each wait
for a response before issuing the next request (the closed model).

Under the closed model, throughput is an *output*: it equals the population
divided by the sum of response time and think time. So a closed test cannot hold
a target rate through a degradation, because the degradation is what reduces the
rate. If the question is "what happens at N requests per second", the model has
to be open. The closed model answers "what happens to N concurrent users", which
is a different question with a different answer, and the two are routinely
reported as if they were the same.

### Concurrency is rate times response time

The number of requests in flight is the arrival rate multiplied by the response
time. That is the sizing equation, and it has an uncomfortable consequence: a
fleet sized on the response time the target shows when it is *healthy* has
exactly enough capacity for the healthy case and runs out as soon as the target
slows down.

What happens next is the part worth knowing. The fleet stops being able to offer
the target rate, so the offered load falls at the moment the target begins to
struggle — and the resulting graph looks like the target recovering. Size on the
response-time ceiling you are willing to observe, not the one you expect.

### A worker's real ceiling is usually its socket budget, not its processor

A connection is identified by its source address, source port, destination
address and destination port. The usable ephemeral port range is therefore a
budget *per destination endpoint*, and how much of it a run consumes depends on
how long each request occupies one of those four-tuples:

| Scenario | Four-tuple occupancy per request | Worker ceiling |
|---|---|---|
| Connections reused | response time | budget / response time |
| New connection per request | response time + socket lingering interval | budget / (response time + lingering interval) |

Connection reuse removes exactly one term from that denominator. Because the
lingering interval is typically one to two orders of magnitude larger than the
response-time ceiling, that single term is the entire difference between the two
rows — which makes connection reuse a *fleet sizing input*, not a scenario
preference. Without reuse, and against a single destination address, one worker
caps at a few hundred requests per second: far below anything its processor
allocation would suggest, and the failure arrives as address-unavailable errors
rather than as saturation.

A socket also needs a file descriptor, so the real budget is whichever of the
two runs out first — and which one that is reverses between environments. This
platform raises the descriptor limit far above the operating system default,
high enough that a single-destination test reaches the port range first; on a
self-managed host the default would bind long before it. The descriptor limit
takes over as soon as the scenario reaches enough destination addresses, because
the four-tuple budget grows with that count and the descriptor limit does not.
At the default port range the crossover is at three destination addresses, and
past it more addresses buy nothing. Both budgets are published, along with which
one supplied the answer, because the remedies are different and neither helps
with the other.

Two further consequences fall out of the same arithmetic:

- The budget scales with the number of distinct destination addresses in
  rotation. One scenario against one service can hit the ceiling at very
  different rates on two runs, with nothing in the scenario changed, purely
  because the target name resolved to a different number of addresses. The
  platform assumes one address unless told otherwise, because one is the
  conservative answer.
- Giving a socket-bound worker more processor does nothing. The configuration
  reports which bound is binding so that the useless remedy is visible as such.

### Both ceilings are published

```
$ terraform output fleet_plan
$ terraform output fleet_bounds
$ terraform output worker_socket_budget
$ terraform output fleet_findings
```

The arithmetic itself needs neither state nor credentials, so a fleet can be
sized and rejected before anything exists:

```
$ terraform console
> local.derived_worker_count
> local.worker_binding_constraint
```

The derived worker count is refused rather than clamped when it exceeds the
configured ceiling, because a silently clamped fleet offers less load than the
run reports.

## The network path is a test variable

Runners either take a public address each, or sit in private subnets and leave
through a NAT gateway. The difference is not plumbing:

- A fleet of separately addressed workers presents the target with as many
  source addresses as there are workers. Any per-source rate limit, connection
  cap or firewall rule on the target path therefore admits roughly that multiple
  of what it would admit from a single client.
- A NAT'd fleet presents one address per gateway, and every byte it sends and
  receives is billed as data processing — which, for a load test, is the whole
  point of the exercise and can cost more than the compute did.

Both are legitimate. They answer slightly different questions, so the platform
records which was used rather than defaulting silently.

## Interruptible capacity is cheap and wrong for comparisons

Reclaimed workers are warned before they stop, and the warning is exactly as
long as the maximum grace period a container may be given. Those two numbers
being equal is the governing constraint: a flush that only begins when the stop
signal arrives has no margin at all. Results are therefore streamed out during
the run rather than written at the end, and the grace period is set below the
cap rather than at it.

The deeper problem is not lost data. A reclaimed worker withdraws its share of
the offered load mid-run, so measured throughput falls — and nothing in the
target's own metrics distinguishes that from the target degrading. The run reads
as a regression in the system under test. Interruptible capacity is appropriate
for exploratory runs, where the question is whether the scenario works at all.
It is not appropriate for a run that establishes or is checked against a
baseline, and the configuration says so with the share it computed.

## Scenarios: a check is not an assertion

Scenarios live in `scenarios/`, built from a shared library. A scenario states
what it asks of the target and what counts as a correct answer; it does not
state the rate, the ramp, the population, the request timeout or whether
connections are reused. Those are the fleet's, and a scenario restating one of
them can disagree with the fleet it is running on without anything in the
result saying so.

The library exists because of one property of the generator: a check RECORDS a
result and does not fail the run. The exit status is decided by thresholds. A
scenario full of checks and no thresholds exits zero with every assertion in it
failing, and a regression gate reading that exit status reports the release as
clean. So checks and the thresholds that make them binding are produced from
one object and cannot be separated.

Three consequences are worth stating here because they decide what a run means.

- A response-time threshold is scoped to the responses the target *meant* to
  send. An error response is faster than a successful one, so a target that
  starts failing fast makes an unscoped percentile better: the figure improves
  while the service degrades.
- A threshold scoped to something that emitted no samples passes, which makes
  every mistyped selector an assertion that can never fail. Check names are
  validated against the selector syntax before use, and a profile naming a
  phase no stage carries is refused.
- An error rate over a whole run tolerates a complete outage lasting the run
  length multiplied by the permitted rate — 36 seconds of a one-hour run at one
  percent. A longer run is a weaker assertion, and the figure is reported per
  run rather than left to be discovered.

The population a worker pre-allocates is the arrival rate multiplied by the
latency ceiling, which is the same equation the fleet size came out of. One
virtual user holds one connection and one connection is one four-tuple, so the
population and the socket budget above are the same bound written twice: at
full socket-bound sizing they are equal by construction, and a population above
the budget is refused rather than attempted.

See [scenarios/README.md](scenarios/README.md) for the profiles, the finding
codes and the authoring contract.

## Permissions: the two roles that get collapsed into one

The platform's agent assumes one role to pull the image and open the log
stream; the scenario inside the container assumes a different one to stream
results, read its run parameters and publish its own metrics. Nothing the
scenario runs can reach the first.

The shortcut is to put the result-writing permission on the execution role,
because that is the role already attached and already working. It is not
equivalent: an execution role is commonly shared across every task definition
in an account, so a permission added there is granted to all of them, and the
blast radius of the grant has nothing to do with this fleet.

Two of the grants here cannot be scoped to a resource at all — registry
authentication returns a token for the caller's whole registry, and metric
publication names no resource. The first is left at a wildcard with that reason
recorded; the second is bounded by a namespace condition, which is the only
boundary that action has. The result grant is write-only and confined to this
fleet's prefix: a runner has no reason to read a previous run's output, and a
generator that could delete it is one bad scenario away from destroying the
baseline it is being compared against.

The trust policy carries the two confused-deputy condition keys, and the source
ARN is a wildcard over the account and region. That is not laziness — scoping it
to a single cluster is not supported, so narrowing it looks like an improvement
and stops every worker in the fleet from starting.

## Results: a percentile does not survive a fleet

A run is a distributed measurement. Every worker measures a sample of the same
experiment, and the run's figure belongs to none of them — which decides the
shape of everything that stores a result.

**Counts and sums combine. Percentiles do not.** Add two workers' request
counts and you have the fleet's count; add their duration sums and divide and
you have the fleet's mean. Take the mean of two workers' 95th percentiles and
you have a number somewhere between the smaller and the larger of them — and so
is every other value in that interval. There is no stated relationship. A
pipeline that averages them produces a latency figure wrong by an unknown
amount that reads exactly like a correct one.

So each worker publishes a **distribution** over one ladder of bucket
boundaries shared by the whole fleet. Counts add, being counts, and the run's
percentile is read off the merged distribution with a cumulative sum.

**What comes back is an interval, not a number.** A bucketed percentile is
known only to the width of the bucket it falls in, so `latency-percentiles.sql`
returns the bracketing boundaries and the width between them rather than
interpolating inside the bucket, which would invent a precision the data does
not have. Two consequences follow, and both are checked rather than documented:

- The ladder **must** carry a boundary at the latency ceiling. That is the one
  figure a run is judged against, so it is the one place a bucket's width would
  decide the verdict. A configuration whose ladder has no boundary there is
  refused.
- The highest boundary behaves differently from all the others. A bucket in the
  middle says "between these two figures"; the top bucket says only "slower
  than this". If a material share of a phase lands there, that phase's tail is
  *unmeasured* and any percentile inside it is a lower bound.
  `ladder-coverage.sql` is how you find out before quoting one.

### Two halves, because the questions have different shapes

| | Metrics | Objects, catalogued |
|---|---|---|
| Answers | what is happening now | what happened in that run |
| Scoped to | the fleet | one run |
| Bounded by | metric retention | the retention set for results |
| Written by | each worker, each interval | each worker, each flush |

The division is not a preference; it falls out of how a metric is identified. A
**dimension combination is the metric**, so dimensioning by run identifier
creates a fresh custom metric for every run — each billed for the calendar
month although it lived for minutes, and none of them nameable by a dashboard
that was written before the run existed. Run attribution therefore lives in the
object store, where it costs a prefix.

### The partitioning makes one question unanswerable, on purpose

`run_samples` is partitioned by date and by run identifier, and the run
identifier is an **injected** projection: reading one run touches one prefix,
and a query with no filter on it *fails* rather than returning everything. That
is deliberate — the table accumulates for as long as the retention allows, and
an accidental scan of all of it is paid for by whoever typed the query — but it
means "what runs are there" cannot be asked of the measurements at all.

`run_index` answers that instead: one row per run, partitioned by date alone,
written from the launcher's own placement record. It is also the only place that
knows what the run **asked for**, as distinct from what it measured. Most
readings of a run need both tables, and the first three queries in the
catalogue exist to settle whether the rest of the numbers mean anything:

```bash
terraform output result_catalog           # database, tables, workgroup, named queries
terraform output result_contract          # key template, flush interval, bucket ladder
```

### Three quantities that get read as one

| | What it is | A shortfall here is |
|---|---|---|
| `target_rate` | what the objective asked for | — |
| `effective_offered_rate` | what the fleet that got placed could ask for | a property of the **launch**: placement failures, a quota, a subnet out of addresses |
| achieved rate | what the target actually served | a property of the **target** — the result |

A gap between the first two is invisible in the target's metrics. Reading it as
a gap between the second and the third is the commonest way a load test reports
a service as healthy at a rate it was never offered.
`offered-vs-achieved.sql` keeps them apart, and `silent_workers` — workers the
launcher placed that never wrote a measurement window — is its sharpest column:
they were billed, they held an address, and they offered nothing.

### A key that is not unique loses a worker silently

A result key carries the worker's **task identifier** and a flush sequence, and
it needs both. A key naming only the worker is overwritten by that worker's
next flush; a key naming only the sequence is overwritten by every other
worker's flush of the same index. Neither overwrite is an error — a PUT to an
existing key succeeds — so the run would report the workers it placed and
silently hold one worker's results. Versioning is enabled for exactly this
reason and no other: it is the only place that collision is visible afterwards.

It is a task identifier rather than an index because one launch request places
identical tasks, so no worker can be told which one it is.

The run index key is the opposite: it names the run and nothing else, so
republishing a corrected report replaces the row rather than adding a second.

### Retention is three lengths, not one

One figure produces three, and the differences are the kind that get discovered
by a query quietly returning fewer rows:

- **Queryable** stops one calendar date before the expiry. Lifecycle expiry is
  not instantaneous, so at the boundary a partition may be whole, part-deleted
  or empty — and a part-deleted partition answers with a smaller number and no
  error. Stopping the projection first means a partition a query can see is one
  that was never due for deletion.
- **Expiry** is when an object's current version stops being current.
- **Stored** is when the bytes actually go: on a versioned bucket an expiry
  makes the current version noncurrent rather than removing it, so the real
  lifetime — and the bill — is the expiry plus the noncurrent window.

Separately, because results are streamed *during* a run and a worker can be
taken away mid-upload, an abandoned multipart upload is billed for its parts
and appears in no object listing. The task role deliberately cannot delete, so
the lifecycle rule that aborts them is the only thing in the account that will
ever clean one up.

## Dashboards: what a dashboard will not show you

Two pages, kept apart deliberately. The **run** view shows what the target did;
the **fleet** view shows what the generator did. The commonest misreading of a
load test is attributing the generator's saturation to the target, and both
look identical from the run view alone — the rate stops rising and latency
climbs. The only thing that settles it is the second set of figures, and
putting them on separate pages means the question has to be asked.

Four properties decide what these can show:

- **A widget's period is a multiple of 60 seconds, minimum 60.** There is no
  sub-minute view. A 90-second smoke run is one or two points on every graph,
  which is not a reading of anything — short runs are read from the query
  catalogue. This is also why publishing at sub-minute resolution buys nothing
  here, and such data is retained for hours rather than weeks, so it is gone by
  the time most people look.
- **`periodOverride` is `inherit`, not `auto`.** Under `auto`, widening the time
  range silently re-periods every graph, and a 95th percentile over a
  five-minute period is a different quantity from one over a minute while the
  widget still says `p95`.
- **`liveData` is on.** Without it the most recent minute — published but not
  fully aggregated — is missing, which on a short run is a large fraction of
  the whole thing.
- **Percentile statistics need values.** From a statistic set a percentile is
  retrievable only in the degenerate case where every sample in the set is
  identical, so a percentile widget over statistic-set data is permanently
  empty. The configuration refuses the combination rather than shipping it.

And one failure with no mitigation other than not making the mistake: creating
a dashboard **succeeds** when its body is merely warnable. The API returns
validation messages, and warnings still create the dashboard with a note that
some elements may not render — so a widget naming a metric nothing publishes
applies cleanly and renders blank. Every metric name, dimension and namespace
on both pages is therefore read out of the same catalogue the result contract
and the publish permission are built from, and the committed SQL is checked
against it too: a query asking for a metric nothing emits fails the plan.

Two lines on the pages are the sizing arithmetic drawn where it can be seen
rather than left in an output: the latency ceiling on the response-time graph,
and the per-worker socket budget on the connections graph. A worker sitting on
that second line cannot open a socket, and the failed request is recorded
against the target's name, because that is what it was aimed at.

## Why a per-run fleet rather than a long-lived one

Workers are launched per run and are expected to exit. A scheduler that
maintains a desired count is the right shape for a standing pool waiting on a
controller, and the wrong shape here, because the two primary outputs of a run
are its exit status and whether its results are complete. Restart semantics
destroy both: a worker that exhausts its memory is replaced and silently rejoins
partway through, so the offered load is neither the target nor anything
recorded, and the run still reports success.

A launch request places a bounded number of tasks, so a fleet larger than that
is launched in several requests, and a successful response can carry placement
failures alongside the tasks it did place. Partial placement is the normal case
and is reconciled rather than trusted — and the reconciliation has teeth, because
a fleet short of its derived size offers proportionally less load while still
reporting the target. By default the launcher stops the workers it did place and
fails, which is only possible because the start instant has not yet passed.

One request places *identical* tasks, which has a consequence worth stating
plainly: a per-worker index cannot be supplied as a launch override, since every
task in the request receives the same overrides. The rate share does not need
one — it is uniform — so the only thing that does is a scenario partitioning its
data, and such a scenario must read its own identity from the task metadata
available inside the container. The launcher assigns indices afterwards, from
the order tasks were placed in, for the run's record rather than for the run.

## Layout

| Path | Contents |
|---|---|
| `versions.tf`, `providers.tf` | Language and provider constraints |
| `variables.tf` | Inputs, each with its bounds and the reason for them |
| `locals.tf` | The sizing arithmetic, one derivation per value |
| `assertions.tf` | Findings about the objective, and the refusals |
| `outputs.tf` | The derived fleet and every bound it rests on |
| `cluster.tf` | Cluster, capacity strategy and the runner log group |
| `iam.tf` | The execution role and the task role, kept apart |
| `runners.tf` | Security group, task definition and placement checks |
| `results.tf` | Result storage, the catalogue, the workgroup and the result contract |
| `dashboards.tf` | The two dashboards, and what a dashboard period will not show |
| `scenarios/` | Test definitions and the shared library they are built from |
| `queries/` | The committed query catalogue, registered as named queries |
| `tools/launch-fleet.py` | Fan-out launcher, reconciliation and the synchronized start |
| `tools/publish-run-index.py` | Writes a launcher report as the run's row in the index |
| `terraform.tfvars.example` | A worked objective with placeholder account values |

## Using it

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform output fleet_plan                    # size before deploying anything
terraform plan
```

Launching, once the fleet is applied:

```bash
python3 tools/launch-fleet.py \
  --cluster "$(terraform output -raw cluster_name)" \
  --task-definition "$(terraform output -raw task_definition_arn)" \
  --workers "$(terraform output -json fleet_plan | jq .worker_count)" \
  --subnet subnet-0123456789abcdef0 \
  --security-group "$(terraform output -raw runner_security_group_id)" \
  --target-rate 40000 --assign-public-ip
```

Nothing is sent without `--execute`: by default the plan is printed and the
process exits.

Recording the run so it can be found and compared later:

```bash
python3 tools/launch-fleet.py --execute ... \
  | python3 tools/publish-run-index.py --execute \
      --contract-parameter "$(terraform output -json result_contract_parameter | jq -r .name)" \
      --cluster "$(terraform output -raw cluster_name)" \
      --task-definition "$(terraform output -raw task_definition_arn)" \
      --scenario http-read.js
```

Two separate steps on purpose. The launcher has no cloud dependency at all —
its dry run needs nothing installed — and that is worth more than saving a
pipe. The second tool reads the bucket and the key template from the same
result contract the workers read, so the layout exists in one place and the
publisher cannot disagree with the catalogue about where a row goes. It also
refuses a report missing any figure a comparison depends on: a row carrying a
null in place of `comparable_to_baseline` reads, to anything that filters on
it, exactly like a run nobody has judged yet.

Reading a run afterwards — the named queries are registered in the fleet's own
workgroup with the same text as the files in `queries/`, and each takes its
run identifier and a date range as positional parameters:

```bash
terraform output result_catalog                # tables, workgroup, named queries
terraform output -json result_findings | jq    # what the stored results will mean
```

Start with `run-index.sql`, then `offered-vs-achieved.sql` and
`worker-skew.sql`. Those three decide whether the rest of the numbers mean
anything: a run with a placement shortfall, a silent worker or a reclaimed one
did not offer the load its target says, and no amount of precision in the
latency figures repairs that. `queries/README.md` has the order and the
parameters.

The runner image must be pinned by digest. A floating tag lets two runs of the
same committed scenario execute different generator code, which makes every
comparison between them unsound while leaving nothing in either result that says
so — so the configuration refuses a tag rather than warning about one. Pinning
interacts with the processor architecture: a digest may refer to a manifest list
covering several architectures or to one architecture's image, and a
single-architecture digest set against the other produces a task that never
starts, reported as an image pull error rather than as a mismatch.

Every account-specific value in this repository is a placeholder. Nothing here
is applied against a real account on your behalf.

## Contributing

Open a Discussion in the repository, or comment on the pull request. For
anything with a security impact, use
[a security advisory](https://github.com/shivajichaprana/load-testing-platform/security/advisories/new)
rather than an issue.

## License

MIT. See [LICENSE](LICENSE).
