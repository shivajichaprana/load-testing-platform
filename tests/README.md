# Suites

Two suites, because there are two languages here and neither wraps the other.
Run both with `./tests/run.sh`, or one at a time with `./tests/run.sh node` and
`./tests/run.sh python`.

Neither suite needs a running fleet, a cloud account, or a target to load. That
is a property worth stating: a suite that needed any of those would be run
rarely, and the faults it is written to catch are the ones that survive being
caught rarely.

## `scenarios/` — the scenario library

The generator's built-in modules (`k6`, `k6/http`, `k6/execution`,
`k6/metrics`) are not packages and do not resolve outside the generator. They
are substituted by a resolver hook registered in
`scenarios/support/register.mjs`, which is why the suite is invoked with
`--import`. The substitutes live under `scenarios/support/` rather than in a
dependency directory on purpose: vendored there, they would sit on the
resolution path of the real scenarios, where a mistaken import of a fixture
would run in a real fleet and succeed.

The substitutes record rather than simulate. `check` returns a result and never
throws, because that is the behaviour the whole library is built around — a
check records a result and the exit status belongs to the thresholds — and the
HTTP client records the URL, the tags and the response type it was asked for,
because those are what a result set is keyed by.

## `baseline/` — the capture and comparison tools

The tools are scripts rather than an installed package, so the suite loads them
from their paths. Measurement documents are built by `capture.build_document`
rather than written as literals, so a fixture cannot drift into a shape no run
can emit.

`test_policy.py` is the cross-artifact audit: the shipped regression policy is
checked against the tool that reads it, the latency ladder in the Terraform
variable, the labels the percentile query emits, and the scenarios the
selectors name. Those four files can each be edited alone, and when they drift
apart nothing fails — a selector stops matching, or an allowance becomes too
narrow for the ladder to resolve. Both are treated as failures here for that
reason.

## What the suites are organised around

A fault that stops a run is found by the first person who attempts one. The
faults worth a suite are the ones that leave a run COMPLETING and reporting a
result:

- a threshold whose selector matches nothing passes, so a mistyped check name,
  a renamed phase or a dropped tag turns an assertion into something that can
  never fail;
- an unscoped latency percentile improves when a target begins failing fast,
  because a rejection costs a connection and a header rather than the work;
- a run-level error-rate threshold tolerates a complete outage lasting the run
  length multiplied by the permitted rate, which makes a longer run a weaker
  assertion than a shorter one;
- a bucketed percentile comparison has a third outcome, and admitting it as a
  pass admits every change too small for the ladder to see.
