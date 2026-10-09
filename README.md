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
$ terraform output fleet_findings
```

These are evaluable with nothing deployed. A fleet can be sized, inspected and
rejected before any capacity exists, and the derived worker count is refused
rather than clamped when it exceeds the configured ceiling — a silently clamped
fleet offers less load than the run reports.

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
and is reconciled rather than trusted.

## Layout

| Path | Contents |
|---|---|
| `versions.tf`, `providers.tf` | Language and provider constraints |
| `variables.tf` | Inputs, each with its bounds and the reason for them |
| `locals.tf` | The sizing arithmetic, one derivation per value |
| `assertions.tf` | Findings about the objective, and the refusals |
| `outputs.tf` | The derived fleet and every bound it rests on |
| `terraform.tfvars.example` | A worked objective with placeholder account values |

## Using it

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform output fleet_plan                    # size before deploying anything
terraform plan
```

The runner image must be pinned by digest. A floating tag lets two runs of the
same committed scenario execute different generator code, which makes every
comparison between them unsound while leaving nothing in either result that says
so — so the configuration refuses a tag rather than warning about one.

Every account-specific value in this repository is a placeholder. Nothing here
is applied against a real account on your behalf.

## Contributing

Open a Discussion in the repository, or comment on the pull request. For
anything with a security impact, use
[a security advisory](https://github.com/shivajichaprana/load-testing-platform/security/advisories/new)
rather than an issue.

## License

MIT. See [LICENSE](LICENSE).
