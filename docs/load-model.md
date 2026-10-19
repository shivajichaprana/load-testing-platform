# The load model

Everything this platform derives comes out of four figures and two choices: the
rate or the population you are asking for, the response time you are still
willing to measure, whether connections are reused, and how many destination
addresses the scenario reaches. This document is the arithmetic in between,
written out, because every derived value is published and an operator reading
`terraform output` is entitled to know where it came from.

The names used here are the names in the configuration. Inputs are `var.<name>`
in [`variables.tf`](../variables.tf), derivations are `local.<name>` in
[`locals.tf`](../locals.tf), and findings are raised in
[`assertions.tf`](../assertions.tf).

- [1. Two models, two different questions](#1-two-models-two-different-questions)
- [2. Concurrency is rate times response time](#2-concurrency-is-rate-times-response-time)
- [3. A worker has two ceilings](#3-a-worker-has-two-ceilings)
- [4. From the worker ceiling to the fleet](#4-from-the-worker-ceiling-to-the-fleet)
- [5. The population and the socket budget are one bound](#5-the-population-and-the-socket-budget-are-one-bound)
- [6. Three rates that get read as one](#6-three-rates-that-get-read-as-one)
- [7. What makes two runs incomparable](#7-what-makes-two-runs-incomparable)
- [8. Where findings come from](#8-where-findings-come-from)
- [9. The worked example, end to end](#9-the-worked-example-end-to-end)

## 1. Two models, two different questions

A generator can be built two ways, and the choice decides what the run is able
to say.

| | Open model | Closed model |
|---|---|---|
| Selected by | `load_model = "open"` | `load_model = "closed"` |
| Sized from | `target_arrival_rate` | `target_virtual_users` |
| Arrivals | issued at a fixed rate regardless of what comes back | issued by a fixed population, each waiting for its response |
| Throughput is | an **input** | an **output** |
| Answers | "what happens at N requests per second" | "what happens to N concurrent users" |

The asymmetry in the last two rows is the whole reason the choice exists. Under
the closed model, throughput equals the population divided by the sum of
response time and think time, so it *falls as the target slows*. A closed test
therefore cannot hold a rate through a degradation — the degradation is what
removes the rate. If the question names a request rate, the model has to be
open.

The two are routinely reported as if they were interchangeable, and the
configuration refuses to participate: setting `target_arrival_rate` while
`load_model = "closed"` raises finding `L108`, because that rate is accepted,
ignored, and then quoted in the write-up of a run that never offered it.

`local.implied_rate_closed_model` exists to make the output visible in advance.
It is the population divided by the latency ceiling — the rate the population
reaches when think time is zero, which is the case the fleet has to be sized
for even when the scenario intends to sleep.

## 2. Concurrency is rate times response time

Requests in flight is arrival rate multiplied by response time. That identity
is the sizing equation:

```
local.required_concurrency = var.target_arrival_rate * local.latency_ceiling_s
```

The term that matters is the second one, and it is the ceiling rather than the
expectation on purpose.

A fleet sized on the response time the target shows while healthy has exactly
enough capacity for the healthy case. When the target slows, each request holds
its slot for longer, in-flight demand rises above what the fleet can hold, and
the generator stops being able to issue arrivals at the configured rate. The
offered load falls.

It falls *at the moment the target begins to struggle*, which is what makes
this the most expensive mistake available here: on a graph of achieved
throughput, a fleet running out of capacity and a target recovering are the
same line. There is nothing in the target's own metrics that distinguishes
them. Size on the slowest response you are still willing to call a measurement,
not the one you expect to see.

`latency_ceiling_ms` is used three times for this reason, and the three uses
have to agree:

1. as the multiplier above, deriving concurrency and therefore the fleet,
2. as the per-worker population the generator pre-allocates (§5),
3. as the **request timeout**, because a request allowed to outlive the ceiling
   holds a socket for longer than the budget was divided by.

## 3. A worker has two ceilings

A connection is identified by four values: source address, source port,
destination address, destination port. A worker's source address is fixed and
the destination port is the service's, so what a worker can hold at once is a
budget over the remaining two — source ports, times distinct destination
addresses.

### The four-tuple budget

```
local.port_budget_per_worker       = var.worker_ephemeral_port_count * var.destination_endpoint_count
local.descriptor_budget_per_worker = var.runner_nofile_limit - var.reserved_descriptors
local.effective_tuple_budget       = min(port_budget_per_worker, descriptor_budget_per_worker)
local.tuple_budget_source          = whichever of the two was smaller
```

Both terms are real budgets and they run out independently, which is why the
smaller is taken and the *source* is published alongside it. The remedies do
not overlap at all: more destination addresses raise the port budget and
nothing else; a higher descriptor limit raises the descriptor budget and
nothing else. An operator told only `28232` cannot tell which lever to pull.

Which one binds also reverses between environments. This platform raises the
descriptor limit far above the operating-system default, high enough that a
single-destination run reaches the port range first; on a self-managed host the
default of a thousand or so would bind long before it. With the shipped
defaults the crossover is at **three** destination addresses, and past it more
addresses buy nothing, because the descriptor limit does not grow with them.

### How long a request occupies a tuple

```
local.tuple_occupancy_s = var.connection_reuse
  ? local.latency_ceiling_s
  : local.latency_ceiling_s + var.socket_linger_seconds
```

With reuse, the socket is handed to the next request as soon as the response is
read, so occupancy is the response time. Without reuse, the tuple is
additionally unusable for the lingering interval that follows an active close —
the fixed wait for any delayed duplicates, not tunable through a socket option.

Connection reuse removes exactly one term from that denominator, and the
removed term is one to two orders of magnitude larger than the one that
remains. That is the entire difference between the two cases, which makes reuse
a **sizing input** rather than a scenario preference. Finding `L102` reports
both ceilings when reuse is off, so the cost of leaving it off is a figure
rather than an opinion.

### The two per-worker rate ceilings

```
local.worker_rate_ceiling_sockets = local.effective_tuple_budget / local.tuple_occupancy_s
local.worker_rate_ceiling_cpu     = var.requests_per_second_per_vcpu * local.task_vcpu
local.worker_rate_ceiling         = min(sockets, cpu)
local.worker_binding_constraint   = "sockets" or "cpu"
```

Publishing which bound is binding is what makes the useless remedy visible as
such. A socket-bound worker given more processor allocation is still
socket-bound, and the fleet does not shrink by a single task; `L101` says so
with both figures. Equally, a processor-bound fleet does not shrink because the
scenario started reusing connections.

The socket bound also fails in a way that does not look like saturation.
Against a single destination address without reuse, a worker caps in the low
hundreds of requests per second — far below anything its processor allocation
suggests — and the symptom is address-unavailable errors, which read as the
target refusing connections.

## 4. From the worker ceiling to the fleet

```
local.workers_for_open_model   = ceil(var.target_arrival_rate / local.worker_rate_ceiling)

local.workers_for_closed_model = max(
  ceil(var.target_virtual_users / local.worker_vu_ceiling_cpu),
  ceil(local.implied_rate_closed_model / local.worker_rate_ceiling_sockets),
)

local.derived_worker_count = open ? workers_for_open_model : workers_for_closed_model
```

The closed-model count takes a maximum of two counts rather than one, because a
population is bounded both by what a worker can *hold* and by the rate that
population implies. Sizing on the first alone produces a fleet that cannot open
the connections its own users need.

**The derived count is refused rather than clamped** when it exceeds the
configured ceiling or the account's capacity quota. A silently clamped fleet
offers less load than the run reports, which is the §6 failure with the
configuration's own fingerprints on it.

Two more properties of the fleet, both consequences of how tasks are placed:

- A launch request places at most ten tasks (`local.run_task_max_count`), so a
  larger fleet is several requests, and a *successful* response can carry
  placement failures beside the tasks it did place. Partial placement is the
  normal case; the launcher reconciles rather than trusts.
- One request places **identical** tasks. No worker can be told which one it
  is, so a per-worker index cannot be supplied as a launch override, and the
  rate share — which is uniform — is the only per-worker figure that needs no
  such index.

## 5. The population and the socket budget are one bound

The generator pre-allocates a population per worker:

```
preAllocatedVUs = ceil(peakRatePerWorker * latencyCeilingSeconds)
```

That is §2's equation again, applied to one worker's share. Sized on the
*expected* latency instead, a worker has exactly enough users for the healthy
case and begins dropping iterations it cannot start the moment the target slows
— which is why `dropped_iterations` is a threshold in every profile and not a
footnote in a report.

One virtual user holds one connection, and one connection is one four-tuple. So
the population and `effective_tuple_budget` are the same bound written twice,
and the relationship between them is exact rather than approximate:

| Binding constraint | Population versus budget | Why |
|---|---|---|
| `sockets` | equal | the worker count was derived by dividing the budget by precisely this product |
| `cpu` | below | the difference is genuine margin |
| — | above | no legitimate case; refused as `L106` |

`L107` warns within ten percent of the budget, because the margin at that point
is smaller than the variation between two runs.

## 6. Three rates that get read as one

| Quantity | What it is | A shortfall here is a property of |
|---|---|---|
| `target_rate` | what the objective asked for | the objective |
| `effective_offered_rate` | what the fleet that actually got placed could ask for | the **launch**: placement failures, a quota, a subnet out of addresses, a reclaimed worker |
| achieved rate | what the target actually served | the **target** — this is the result |

Only the gap between the second and the third is a finding about the system
under test. The gap between the first and the second is invisible in the
target's metrics, and reading it as if it were the second gap is the commonest
way a load test certifies a service at a rate it was never offered.

`offered-vs-achieved.sql` keeps the three apart, and its sharpest column is
`silent_workers`: workers the launcher placed that never wrote a measurement
window. They were billed, they held an address, and they offered nothing.

## 7. What makes two runs incomparable

A baseline is a set of figures *plus the conditions under which those figures
mean anything*, and the conditions are the part that gets dropped. Two honest
latency figures from two different offered rates cannot be subtracted. Neither
can two figures aggregated over different bucket ladders, nor a full fleet and
a fleet three workers short.

So the conditions travel inside the measurement document, and the comparison
checks them before taking any verdict:

| Condition | Checked by | Why a difference voids rather than fails |
|---|---|---|
| Offered rate | `offered_rate_tolerance_pct` | a different rate is a different experiment |
| Bucket ladder | the ladder fingerprint | percentiles read off different boundaries are different quantities |
| Scenario | `require_same_scenario` | a different question |
| Fleet completeness | `require_comparable` | a short fleet offered proportionally less |

A **void** comparison and a **failed** one need different responses from
whoever reads the report, so they carry different exit codes:

| Exit | Outcome | Means |
|---|---|---|
| `0` | pass | the candidate's whole interval sits at or below the allowed ceiling |
| `1` | regressed | the candidate's whole interval sits above it |
| `2` | unresolved | the interval straddles it; nothing follows from the data |
| `3` | void | the runs are not comparable, so no verdict was taken |
| `4` | usage | the input is not a pair of measurement documents |

`unresolved` is not a hedge. A percentile read off a ladder is known only to
the width of its bucket, so when the candidate's interval straddles the allowed
ceiling, neither verdict follows. Its remedy is specific and the report prints
it: add a ladder boundary at the ceiling the gate tests against. That
invalidates the baselines captured under the old ladder — the fingerprint check
will say so — and that is the honest price of resolving a gate rather than
guessing it.

Interruptible capacity belongs in this section rather than in a cost one. A
reclaimed worker withdraws its share of the offered load mid-run, so measured
throughput falls and nothing in the target's metrics separates that from the
target degrading. The run reads as a regression. Spot capacity is right for
exploratory runs, where the question is whether the scenario works at all, and
wrong for any run that establishes or is judged against a baseline — and the
configuration says so with the share it computed rather than leaving it to be
remembered.

## 8. Where findings come from

Findings are reported in three places, and two of them use the same code shape
for different sets of codes. Worth knowing before searching for one:

| Codes | Raised by | Read with |
|---|---|---|
| `L101`–`L112` | the configuration, about the objective | `terraform output fleet_findings` |
| `R101`–`R108` | the configuration, about stored results | `terraform output result_findings` |
| `L101`–`L108`, `C101`–`C103` | the **scenario library**, about the profile and the checks | printed by the generator at startup; tabulated in [`scenarios/README.md`](../scenarios/README.md) |

The two `L1xx` ranges are separate namespaces that happen to share a prefix.
The configuration's are about the fleet you are about to create; the library's
are about the run a worker is about to start. A severity of `error` in either
place is a refusal rather than a warning, and each one describes a run that
would otherwise have *passed* without measuring what it claims to.

## 9. The worked example, end to end

From [`terraform.tfvars.example`](../terraform.tfvars.example), with the shipped
defaults for everything it does not set.

```
target_arrival_rate          = 40000     requests per second
latency_ceiling_ms           = 2000      so latency_ceiling_s = 2.0
connection_reuse             = true
destination_endpoint_count   = 1
worker_ephemeral_port_count  = 28232     (default)
runner_nofile_limit          = 65535     (default)
reserved_descriptors         = 256       (default)
runner_cpu                   = 2048      so task_vcpu = 2
requests_per_second_per_vcpu = 1500
account_fargate_vcpu_quota   = 64
```

The derivation:

```
port_budget_per_worker       = 28232 * 1          = 28232
descriptor_budget_per_worker = 65535 - 256        = 65279
effective_tuple_budget       = min(28232, 65279)  = 28232     source: ports
tuple_occupancy_s            = 2.0                            (reuse on)
worker_rate_ceiling_sockets  = 28232 / 2.0        = 14116 rps
worker_rate_ceiling_cpu      = 1500 * 2           =  3000 rps
worker_rate_ceiling          = min(14116, 3000)   =  3000 rps  binding: cpu
required_concurrency         = 40000 * 2.0        = 80000 requests in flight
derived_worker_count         = ceil(40000 / 3000) = 14 workers
fleet_vcpu                   = 14 * 2             = 28 vCPU   (quota 64, fits)
```

Per worker: a rate share of about 2857 requests per second, and a pre-allocated
population of about 5714 users against a budget of 28232. The margin is real,
and §5 says why — this fleet is processor-bound, so the population lands below
the budget rather than on it.

Now change one boolean. With `connection_reuse = false`:

```
tuple_occupancy_s           = 2.0 + 60             = 62.0
worker_rate_ceiling_sockets = 28232 / 62.0         = 455 rps   binding: sockets
derived_worker_count        = ceil(40000 / 455.35) = 88 workers
fleet_vcpu                  = 88 * 2               = 176 vCPU
```

Fourteen workers become eighty-eight, the binding constraint moves from the
processor to the socket, and the fleet is **refused** — 176 vCPU against a
quota of 64. Nothing about the objective changed. The lingering interval is
thirty-one times the latency ceiling, and the whole of that factor passes
straight into the fleet size.

This is also the sense in which the arithmetic is worth having before anything
exists. None of it needs state or credentials:

```bash
make size          # the derived fleet, both bounds, and the findings

terraform console  # or interrogate one value at a time
> local.derived_worker_count
> local.worker_binding_constraint
> local.effective_tuple_budget
```

A fleet can be sized, argued with, and rejected before a single task is placed.
