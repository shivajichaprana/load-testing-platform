# Scenarios

Test definitions, and the shared library they are built from. A scenario file
states what it asks of the target and what counts as a correct answer. It does
not state the rate, the ramp, the population, the request timeout or whether
connections are reused — those come from the launch contract, because a
scenario that restates one of them can disagree with the fleet it is running
on, and nothing in the result says so.

| Path | Contents |
|---|---|
| `lib/runtime.js` | The launch contract, worker identity, and address joining |
| `lib/stages.js` | Profiles, the sizing arithmetic, and plan findings |
| `lib/checks.js` | Shared checks, the thresholds they imply, and check findings |
| `lib/options.js` | Composition: contract plus profile plus checks into options |
| `http-read.js` | A read path held at the objective |
| `http-write.js` | A write path, each worker writing its own slice of the keys |
| `user-journey.js` | A multi-step circuit under the closed model |

## A check is not an assertion

A check records a result. It does not fail the run: the exit status is decided
by **thresholds**. A scenario full of checks and no thresholds exits zero with
every assertion in it failing, and a regression gate reading that exit status
reports the release as clean.

So the library never hands back a check on its own. `suite()` returns the
predicates, and `thresholds()` returns the gates that make them binding, from
the same object:

```js
const readChecks = suite('read path', [statusIs(200), jsonFieldPresent('items')]);
const built = openModelOptions({ suite: readChecks, profileName: 'steady', ctx });
export const options = built.options;   // scenarios + thresholds together
```

Three properties of the measurement follow from the same idea.

**A latency threshold is scoped to the responses the target meant to send.** An
error response is faster than a successful one — a rejection costs a connection
and a header, not the work — so a target that starts failing fast makes the
unscoped response-time percentile *better*. Every latency threshold the library
emits selects on `expected_response:true` for that reason.

**A threshold scoped to something that produced no samples passes.** That makes
every mistyped selector an assertion that can never fail, which is why check
names are validated against the selector syntax before they can be used, and
why a profile naming a phase that no stage carries is refused rather than
warned about.

**An error rate over a whole run dilutes a short outage.** At a steady arrival
rate, a run of length `T` passes a threshold of "error rate below `e`" through a
complete outage lasting up to `T x e` — 36 seconds of a one-hour run against a
one-percent threshold. The figure is computed per run and reported as finding
`C101`; the remedy is a shorter judged phase, not a lower rate alone.

## Profiles

A profile is a shape, expressed as fractions of the rate *this worker* was
given. `thresholdPhases` names the phases the profile is willing to be judged
on.

| Profile | Shape | Judged on |
|---|---|---|
| `smoke` | A minute at one percent of the objective | `steady` |
| `steady` | Ramp, hold, drain. The default | `steady` |
| `staircase` | Quarter steps to the objective, then hold | `steady` |
| `soak` | Two hours at the objective | `steady` |
| `spike` | Baseline, a sudden five-fold rise, and the return | `baseline`, `recovery` |

The spike profile is why that last column exists. Asserting a latency ceiling
during the spike makes the profile unpassable by construction — the spike is
the thing being provoked. What it can be judged on is whether the baseline was
healthy beforehand and whether it came back.

Every stage carries a phase, and each request is tagged with the phase it was
made in. A percentile taken over a whole run mixes the ramp with the hold, and
those are different loads, so the number describes neither.

## Two bounds that are one bound

The population a worker pre-allocates is the arrival rate multiplied by the
latency **ceiling** — the same equation the fleet size came out of, and
deliberately not the latency anyone expects. A population sized on the expected
latency has exactly enough users for the healthy case; when the target slows,
the generator cannot hold enough requests in flight to maintain the rate, and
the iterations it cannot start are dropped. The offered load then falls at the
one moment that fall is indistinguishable from the target recovering, which is
why `dropped_iterations` is a threshold and not a footnote.

One virtual user holds one connection and one connection is one four-tuple, so
that population and the worker's socket budget are the same bound written
twice. When the socket bound is the binding one, the fleet size was derived by
dividing the budget by exactly that product — so the population comes out equal
to the budget, and the parity is exact rather than lucky. When the processor
bound is binding, the population comes out below it and the difference is real
margin. Above it there is no legitimate case, and `L106` refuses it.

The request timeout is the ceiling for the same reason: a request allowed to
outlive it occupies a socket for longer than the budget was divided by.

## Findings

Errors are refused before the run starts. Each one produces a run that would
otherwise *pass* without having measured what it claims to.

| Code | Severity | Meaning |
|---|---|---|
| `L101` | error | A judged phase has no stages, so its thresholds match nothing |
| `L102` | error | The pre-allocated population exceeds its own ceiling |
| `L103` | error | Graceful stop plus flush reserve exceeds the container's stop timeout |
| `L104` | warn | The profile ends above zero, so the last interval reports cut-off requests |
| `L105` | error | The peak rate cannot be held at the ceiling within the population ceiling |
| `L106` | error | The population exceeds the worker's four-tuple budget |
| `L107` | warn | The population is within ten percent of that budget |
| `L108` | warn/note | What the downward rounding of the peak stage costs the objective |
| `C101` | warn/note | The longest complete outage the error-rate threshold tolerates |
| `C102` | note | The suite reads bodies, so retained bodies scale with the population |
| `C103` | error | No checks are recorded, so the per-check thresholds cover nothing |

## Inputs

From the launch contract, set by the task definition or by the launch override.
A scenario reads these and does not override them.

| Variable | Meaning |
|---|---|
| `RUNNER_RUN_ID` | The run this worker belongs to |
| `RUNNER_START_EPOCH` | The wall-clock second every worker waits for |
| `RUNNER_WORKER_COUNT` | Workers in the fleet |
| `RUNNER_RATE_SHARE` | **This worker's** share of the offered rate |
| `RUNNER_LOAD_MODEL` | `open` or `closed`; a scenario built for the other is refused |
| `RUNNER_CONNECTION_REUSE` | Whether connections are reused — a sizing input |
| `RUNNER_LATENCY_CEILING_MS` | The sizing ceiling, and the request timeout |
| `RUNNER_TUPLE_BUDGET` | Connections one worker may hold at once |
| `RUNNER_STOP_TIMEOUT_SECONDS` | Time between the stop signal and the kill |
| `RUNNER_METRIC_NAMESPACE`, `RUNNER_PARAMETER_PREFIX`, `RUNNER_ARTIFACT_BUCKET`, `RUNNER_ARTIFACT_PREFIX` | Where a run's output goes |

Per scenario, with defaults where one is sound:

| Variable | Meaning |
|---|---|
| `TARGET_BASE_URL` | Required. No default: a scenario pointed at nothing reports the target as down |
| `PROFILE` | One of the profiles above; `steady` by default |
| `READ_PATH`, `READ_PAGE_SIZE` | `http-read.js` |
| `WRITE_PATH`, `WRITE_KEYS_PER_PARTITION` | `http-write.js` |
| `VIRTUAL_USERS`, `THINK_TIME_MS` | `user-journey.js` |

## Worker identity

A scenario that partitions its data needs to know which worker it is, and
there are two tempting answers that are both wrong.

The virtual user number restarts at one in every worker, because each worker is
a separate generator process — so partitioning by it has every worker taking
the same partition, and the run reports having covered a key space it contended
on a fraction of. A launch override cannot carry it either: one launch request
places identical tasks, so every task in the request receives the same
overrides.

The task's own metadata is the only per-worker fact inside the container.
`partitionIndex()` refuses when it cannot be read, rather than defaulting to
zero, because the default is silent and produces exactly the run above.

## Writing a scenario

1. Build a check suite. Give each check a static name — every distinct name
   becomes a sub-metric, so a name carrying an identifier grows the result set
   per request and leaves no name a threshold can select.
2. Pass the suite to `openModelOptions` or `closedModelOptions` and export what
   comes back as `options`. Findings print at startup; errors stop the run.
3. Put the synchronized-start barrier in `setup()`, never in a virtual user: a
   user that sleeps has spent an iteration doing it, and the iteration is the
   unit the arrival rate is expressed in.
4. Take the suite's own request parameters from `suite.params()`. A body-reading
   suite asks for the body explicitly, so bodies can be discarded globally
   without silently disabling the assertions that need them.
5. Tag every request with its phase, from `phaseAt()`.

`setup()` runs once per **worker**, not once per run — each worker is its own
generator process. Anything in it that creates state creates it as many times
as there are workers.
