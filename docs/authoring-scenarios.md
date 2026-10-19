# Authoring scenarios

A scenario is the only part of this platform that describes the service under
test. It states what it asks of the target and what counts as a correct answer,
and that is all it states. This document is the contract and the library
reference behind that sentence.

[`scenarios/README.md`](../scenarios/README.md) is the short form — the profile
table, the finding codes and the inputs. This is the long form, for writing a
new one.

- [1. What a scenario owns](#1-what-a-scenario-owns)
- [2. The shape of a scenario file](#2-the-shape-of-a-scenario-file)
- [3. Checks](#3-checks)
- [4. Suites](#4-suites)
- [5. Thresholds are what make a check binding](#5-thresholds-are-what-make-a-check-binding)
- [6. Profiles and phases](#6-profiles-and-phases)
- [7. Tagging a request with its phase](#7-tagging-a-request-with-its-phase)
- [8. The options builders](#8-the-options-builders)
- [9. Closed-model scenarios](#9-closed-model-scenarios)
- [10. Partitioning data across workers](#10-partitioning-data-across-workers)
- [11. Findings](#11-findings)
- [12. Checking a scenario before it reaches a fleet](#12-checking-a-scenario-before-it-reaches-a-fleet)
- [13. Checklist](#13-checklist)

## 1. What a scenario owns

| A scenario states | A scenario never states |
|---|---|
| which requests it makes | the arrival rate |
| what a correct response looks like | the ramp or the hold |
| which fields or headers it reads | the pre-allocated population |
| how it partitions its data, if it does | the request timeout |
| the phase tag on each request | whether connections are reused |

Everything in the right column arrives through the launch contract, read once
by `launchContext()`. The reason is not tidiness. Each of those figures was
used by the sizing arithmetic to derive the fleet, so a scenario that restates
one can disagree with the fleet it is running on — and the result carries the
figure the fleet published, not the one the scenario used. Nothing in the
output says they differed.

`launchContext(env)` returns a frozen object with these fields, and refuses at
startup if any required variable is missing or out of range:

| Field | From | Meaning |
|---|---|---|
| `runId` | `RUNNER_RUN_ID` | the run this worker belongs to |
| `startEpoch` | `RUNNER_START_EPOCH` | the wall-clock second every worker waits for |
| `workerCount` | `RUNNER_WORKER_COUNT` | workers in the fleet |
| `ratePerWorker` | `RUNNER_RATE_SHARE` | **this worker's** share of the offered rate |
| `fleetRate` | derived | `ratePerWorker * workerCount` |
| `loadModel` | `RUNNER_LOAD_MODEL` | `open` or `closed` |
| `connectionReuse` | `RUNNER_CONNECTION_REUSE` | a sizing input, not a preference |
| `latencyCeilingMs` | `RUNNER_LATENCY_CEILING_MS` | the sizing ceiling, and the request timeout |
| `tupleBudget` | `RUNNER_TUPLE_BUDGET` | connections one worker may hold at once |
| `stopTimeoutSeconds` | `RUNNER_STOP_TIMEOUT_SECONDS` | stop signal to kill |
| `metricNamespace`, `parameterPrefix`, `artifactBucket`, `artifactPrefix` | contract | where the run's output goes |

`tupleBudget` is **delivered** rather than recomputed in the scenario, and that
is deliberate: a second derivation of a figure is a second number that agrees
today.

Per-scenario inputs are read with `optionalText` / `optionalNumber`, which take
a default, and `requireTargetBaseUrl`, which does not — a scenario pointed at
nothing reports the target as down, so there is no sound default for it.

## 2. The shape of a scenario file

Three parts, in this order, and the order matters because the generator
evaluates the module body once per worker before any user runs.

```js
import http from 'k6/http';
import exec from 'k6/execution';
import { sleep } from 'k6';

import {
  defaultEnv, endpoint, launchContext, optionalNumber, optionalText,
  requestTimeout, requireTargetBaseUrl, waitForStartInstant,
} from './lib/runtime.js';
import { phaseAt } from './lib/stages.js';
import { jsonFieldPresent, latencyUnder, statusIs, suite } from './lib/checks.js';
import { openModelOptions } from './lib/options.js';

// 1. Module body: read the contract, build the suite, build the options.
const env = defaultEnv();
const ctx = launchContext(env);
const baseUrl = requireTargetBaseUrl(env);
const searchPath = optionalText(env, 'SEARCH_PATH', '/search');
const pageSize = optionalNumber(env, 'SEARCH_PAGE_SIZE', 25);

const searchChecks = suite('search path', [
  statusIs(200),
  jsonFieldPresent('results'),
  latencyUnder(ctx.latencyCeilingMs),
]);

const built = openModelOptions({
  suite: searchChecks,
  profileName: optionalText(env, 'PROFILE', 'steady'),
  ctx,
});

export const options = built.options;   // scenarios AND thresholds, together

// 2. setup(): once per WORKER. The synchronized-start barrier belongs here.
export function setup() {
  const start = waitForStartInstant(ctx, { sleep, now: () => Date.now() / 1000 });
  return { runId: ctx.runId, start };
}

// 3. The default export: one iteration, which is one arrival.
export default function search() {
  const elapsedMs = Date.now() - exec.scenario.startTime;
  const phase = phaseAt(elapsedMs, built.plan.windows);

  const response = http.get(
    endpoint(baseUrl, `${searchPath}?limit=${pageSize}`),
    searchChecks.params({
      tags: { name: 'search', phase },
      timeout: requestTimeout(ctx),
    }),
  );

  searchChecks.run(response, { phase });
}
```

Four properties of that skeleton are load-bearing.

**`setup()` runs once per worker, not once per run.** Each worker is its own
generator process. Anything in `setup()` that creates state in the target
creates it as many times as there are workers, and a scenario that seeds a
fixture there seeds it once per worker.

**The start barrier goes in `setup()`, never in a user.** A user that sleeps has
spent an iteration doing it, and the iteration is the unit the arrival rate is
expressed in — so a barrier inside a user removes arrivals from the very figure
the fleet was sized to produce.

**`endpoint()` joins, it does not resolve.** The platform's own URL handling is
a resolver: an absolute path replaces the whole path, and a leading double
slash is read as a host. Either one silently points the run somewhere else
while every result is still filed under this target's name, so `endpoint()`
compares the resulting origin rather than trusting it.

**`requestTimeout(ctx)` is the ceiling, not a figure of the scenario's own.**
Above it, a request holds a socket for longer than the budget was divided by.
Below it, the run abandons responses the objective says are still being
measured — a different experiment.

## 3. Checks

A check is `{ name, readsBody, predicate }`. Use the constructors; they produce
frozen objects with validated, static names.

| Constructor | Name it produces | Reads the body |
|---|---|---|
| `statusIs(code)` | `status is <code>` | no |
| `statusIn([codes])` | `status in <a>/<b>` | no |
| `headerPresent(name)` | `header <name> is present` | no |
| `latencyUnder(ms)` | `response within the ceiling` | no |
| `bodyContains(fragment)` | `body carries the expected content` | **yes** |
| `jsonFieldPresent(path)` | `field <path> is present` | **yes** |
| `jsonFieldEquals(path, value)` | `field <path> is as expected` | **yes** |

Two of these deserve their own paragraph.

`bodyContains` exists because **a status check is not a success check.** An
error document returned with a success status passes every status check ever
written, and plenty of services do exactly that. At least one check in a suite
should look at what came back.

`latencyUnder` is **not** the latency threshold. The threshold answers "was the
percentile inside the ceiling"; this check answers "what share of responses
were over it". Those are different quantities, and together they distinguish a
percentile missed by a little everywhere from one missed by a lot in one place.
Neither implies the other, so both are kept.

Every check name becomes a sub-metric and a threshold selector. So:

- Names must be **static**. A name carrying an identifier, a URL or a key grows
  the result set by one sub-metric per request and leaves no name a threshold
  can be written against.
- Names are validated with `assertSelectable()` against the selector syntax
  before use, because a threshold scoped to something that emitted no samples
  **passes** — a mistyped selector is otherwise an assertion that can never
  fail.

## 4. Suites

`suite(name, checks)` groups them, and refuses three things outright: an empty
list, something that is not a check, and two checks under one name (two checks
sharing a name share a sub-metric, so one threshold covers both and neither
result can be read on its own).

What it returns:

| Member | Use |
|---|---|
| `name`, `names`, `checks` | the suite's name, the check names, the checks |
| `readsBody` | **derived** from the checks, not declared |
| `map()` | the predicate map the generator's check function takes |
| `params(extra)` | the request parameters this suite needs |
| `run(response, tags)` | record the suite against a response; returns whether all passed |

`params()` is the member worth understanding. Bodies are discarded globally —
`discardResponseBodies: true` — because a retained body is held for the length
of an iteration, so its memory cost scales with the population, which is the
largest figure in the plan. A body-reading suite therefore asks for the body
back **explicitly**, per request:

```js
searchChecks.params({ tags: { name: 'search', phase }, timeout: requestTimeout(ctx) })
// => { tags: { suite: 'search path', name: 'search', phase },
//      responseType: 'text',            // because a check in it reads the body
//      timeout: '2000ms' }
```

That is what lets bodies be discarded for the whole run without silently
switching off the assertions that need them. Build request parameters from
`params()` rather than by hand.

## 5. Thresholds are what make a check binding

The one property of the generator that decides the shape of this library:

> **A check records a result. It does not fail the run.** The exit status is
> decided by thresholds.

A scenario full of checks and no thresholds exits zero with every assertion in
it failing, and a regression gate reading that exit status reports the release
as clean. So the library never hands back a check on its own: `suite()` gives
the predicates and `thresholds()` gives the gates that make them binding, from
the same object, and the options builders call both.

For each phase the profile is willing to be judged on, `thresholds()` emits:

| Selector | Gate | Why scoped this way |
|---|---|---|
| `http_req_duration{expected_response:true,phase:<p>}` | `p(95) < latencyCeilingMs` | the phase keeps the ramp out of the percentile; `expected_response` keeps fast rejections out of it |
| `http_req_failed{phase:<p>}` | `rate < maxErrorRate`, aborting | an error rate is the figure a run is stopped on |
| `checks{check:<name>,phase:<p>}` | `rate >= minCheckPassRate` | a named assertion failing is attributable rather than averaged away |

Plus two whole-run gates: `checks`, so that a check outside every judged phase
still counts for something, and `dropped_iterations`.

Four consequences are worth stating, because they decide what a run means.

**A latency threshold is scoped to responses the target meant to send.** An
error response is cheaper to produce than a correct one — a rejection costs a
connection and a header, not the work — so a target that starts failing fast
makes an unscoped percentile *better*. The figure improves while the service
degrades. Every latency threshold the library emits carries
`expected_response:true` for this reason alone.

**The ceiling in the gate is the ceiling the fleet was sized with.** It is read
off the plan rather than configured again, so the two cannot become two numbers
that merely agree today.

**The abort is delayed by the ramp the plan actually has.** Early in a run the
sample is small enough that a handful of connection errors exceed any rate, so
an abort evaluated from the first second stops runs that were about to be fine.
The delay is computed from the plan's ramp rather than configured.

**`dropped_iterations` is omitted rather than loosened** when the executor
cannot drop an iteration at all. A threshold nothing can breach reads, to
anyone auditing the run, exactly like one that was checked.

And one piece of arithmetic to keep in view: **an error rate over a whole run
dilutes a short outage.** At a steady arrival rate, a run of length `T` passes a
threshold of "error rate below `e`" through a complete outage lasting up to
`T x e` — 36 seconds of a one-hour run against a one-percent threshold.
`blindOutageSeconds()` computes it and finding `C101` reports it. The remedy is
a shorter judged phase, not a lower rate alone.

## 6. Profiles and phases

A profile is a **shape**, expressed as fractions of the rate this worker was
given, so the same profile produces the same shape on a fleet of four workers
and a fleet of forty.

| Profile | Shape | Judged on |
|---|---|---|
| `smoke` | a minute at one percent of the objective | `steady` |
| `steady` | ramp, hold, drain — the default | `steady` |
| `staircase` | quarter steps to the objective, then hold | `steady` |
| `soak` | two hours at the objective | `steady` |
| `spike` | baseline, a sudden five-fold rise, the return | `baseline`, `recovery` |

`thresholdPhases` is that last column, and `spike` is why it exists. Asserting
a latency ceiling *during* the spike makes the profile unpassable by
construction — the spike is the thing being provoked. What a spike run can be
judged on is whether the baseline was healthy beforehand and whether it came
back.

Every stage carries a phase and every request is tagged with the phase it was
made in, because a percentile over a whole run mixes the ramp with the hold.
Those are different loads, so the number describes neither.

A profile naming a phase that no stage carries is **refused** (`L101`), not
warned about: its thresholds would select nothing and pass.

## 7. Tagging a request with its phase

```js
const elapsedMs = Date.now() - exec.scenario.startTime;
const phase = phaseAt(elapsedMs, built.plan.windows);
```

Elapsed time is taken from the **scenario's** start instant, not the run's.
This is the subtlest rule in the library and the easiest to get wrong.

The run's start includes the synchronized-start barrier from `setup()`, and
that wait is a *different length on every worker in the fleet* — workers are
placed at different moments and each waits out the remainder to the shared
start instant. Measuring elapsed time from the run's start would therefore tag
the same request with a different phase on two workers, which is the one thing
a phase tag must not do: the phase is what keeps the ramp out of the
percentile, and a phase boundary that moves per worker smears the two together
in a way nothing in the result reveals.

A request that is not part of the measurement should carry **no** phase tag, so
that it sits outside every phase-scoped threshold. The metadata probe in
[`scenarios/http-write.js`](../scenarios/http-write.js) is the worked example:
a probe of the container's own metadata is not part of the experiment and
should not be able to fail the run's gates.

## 8. The options builders

`openModelOptions({ suite, ctx, ... })` builds the plan, prints the findings,
and returns `{ plan, options }`. It **refuses** when `ctx.loadModel !== 'open'`
— the fleet was sized for the other model, so running this scenario on it
offers a different load from the one the sizing arithmetic was published for.

| Option | Default | Change it when |
|---|---|---|
| `profileName` | `'steady'` | another shape in §6 is the question |
| `durationScale` | `1` | a shorter rehearsal of the same shape is wanted |
| `populationHeadroom` | `1.25` | rarely; it is margin above the pre-allocated population |
| `gracefulStopSeconds` | `30` | the scenario needs longer to finish an iteration |
| `flushReserveSeconds` | `15` | results take longer to flush than the reserve allows |
| `maxErrorRate` | `0.01` | the objective names a different one |
| `latencyPercentile` | `'p(95)'` | the objective is written against another percentile |
| `minCheckPassRate` | `0.99` | the objective tolerates a different share |
| `maxDropShare` | `0` | never, except `null` where the executor cannot drop |
| `scenarioName` | `'load'` | the generator's scenario key matters to a reader |

`latencyPercentile` must be written as `p(95)`: an unparseable statistic is
rejected at startup rather than quietly ignored, which is the one good outcome
available there.

Two values in the returned `options` come from the contract rather than from
the scenario, and both are repeated here because overriding them is the
mistake. `noConnectionReuse` is `!ctx.connectionReuse` — a scenario switching
reuse off changes the worker's socket ceiling by one to two orders of magnitude
while the fleet still reports the size it derived — and the request timeout is
`requestTimeout(ctx)`.

The returned `plan` carries what a scenario needs at runtime: `windows` for
`phaseAt`, and `profileName`, `peakRate`, `totalDuration`, `preAllocatedVUs`,
`latencyCeilingMs`, `thresholdPhases` and `phaseDurations` for reporting.

## 9. Closed-model scenarios

`closedModelOptions({ suite, virtualUsers, ctx, thinkTimeMs, ... })` builds a
fixed population, each user waiting for its own response. It refuses when the
fleet was launched open.

Here `virtualUsers` is a **scenario input**, not a contract value, because the
contract carries a rate and this model does not take one. The rate it will
offer is computed and reported instead: the population divided by the sum of
response time and think time. `impliedRate()` is the function, and
[`scenarios/user-journey.js`](../scenarios/user-journey.js) is the worked
example — a multi-step circuit, where the circuit rather than the request is
the unit.

Think time sits in that denominator, so raising it lowers the offered rate.
Sizing has to assume the zero-think-time case, which is the highest rate a
given population can reach.

## 10. Partitioning data across workers

A scenario that writes needs each worker on its own slice of the key space, and
there are two tempting answers that are both wrong.

**The virtual user number** restarts at one in every worker, because each
worker is a separate generator process. Partitioning by it gives every worker
the same partition, and the run reports having covered a key space it contended
on a fraction of.

**A launch override** cannot carry an index either: one launch request places
*identical* tasks, so every task in the request receives the same overrides.

The task's own metadata is the only per-worker fact available inside the
container:

```js
const partition = partitionIndex(readTaskIdentity(), ctx.workerCount);
```

`partitionIndex(identity, partitions)` **refuses** when the identity cannot be
read, rather than defaulting to zero. A default of zero is the worst available
answer: silent, identical on every worker, and it produces exactly the run
above.

One honest caveat about the implementation. The identifier is an opaque
hexadecimal task id rather than a counter, so the index is a hash
(`stableIndex`) and the distribution is only approximately uniform. For a fleet
of a few dozen that is a real imbalance, and it is described as a hash rather
than as even.

## 11. Findings

Printed by the generator at startup, before any request. An `error` is a
refusal; each one describes a run that would otherwise have **passed** without
measuring what it claims to.

| Code | Severity | Meaning |
|---|---|---|
| `L101` | error | a judged phase has no stages, so its thresholds match nothing |
| `L102` | error | the pre-allocated population exceeds its own ceiling |
| `L103` | error | graceful stop plus flush reserve exceeds the container's stop timeout |
| `L104` | warn | the profile ends above zero, so the last interval reports cut-off requests |
| `L105` | error | the peak rate cannot be held at the ceiling within the population ceiling |
| `L106` | error | the population exceeds the worker's four-tuple budget |
| `L107` | warn | the population is within ten percent of that budget |
| `L108` | warn/note | what downward rounding of the peak stage costs the objective |
| `C101` | warn/note | the longest complete outage the error-rate threshold tolerates |
| `C102` | note | the suite reads bodies, so retained bodies scale with the population |
| `C103` | error | no checks are recorded, so the per-check thresholds cover nothing |

These are the **library's** codes. The configuration raises its own `L1xx`
range about the fleet, read with `terraform output fleet_findings`; the two
namespaces share a prefix and nothing else. See
[`load-model.md`](load-model.md) for the split.

## 12. Checking a scenario before it reaches a fleet

Nothing here needs an install, a cluster or a target:

```bash
make test-scenarios     # the library suite and the entrypoint suite
make lint               # includes the import gate below
```

The suite runs on the standard library's own test runner, with the generator's
built-in modules substituted by a resolver hook
(`tests/scenarios/support/register.mjs`). That hook is the reason for the
import gate in the pipeline: it substitutes a fixed set of built-in module
names, so an import of anything *else* resolves in a test runtime, where a
package manager exists, and fails inside the generator, where one does not. It
would pass every other gate and break on the fleet. Imports are therefore
restricted to the generator's own modules and relative paths.

`tests/scenarios/entrypoints.test.mjs` builds and executes every committed
scenario once against stand-ins. It answers a different question from the
library suite: the library can be entirely correct while a scenario emits
requests with no phase tag, in which case every phase-scoped threshold selects
nothing, all of them pass, and the run reports a clean result having asserted
nothing. A new scenario is picked up by that suite automatically and needs no
registration.

## 13. Checklist

1. Build a suite. Static names, and at least one check that looks at the body.
2. Pass it to `openModelOptions` or `closedModelOptions` and export the result
   as `options`. Read the findings it prints.
3. Put the start barrier in `setup()`, never in a user.
4. Take request parameters from `suite.params()`, never by hand.
5. Tag every measured request with `phaseAt()`, from the scenario's own start
   instant. Leave non-measurement requests untagged.
6. Use `requestTimeout(ctx)`. Do not set a timeout of the scenario's own.
7. Import only the generator's modules and relative paths.
8. Run `make test-scenarios` and `make lint`.
9. Size the fleet for it: `make size` reports the worker count, the binding
   constraint and the findings before anything is created.
