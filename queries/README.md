# Query catalogue

Eight queries over two tables. Every file here is registered as a named query
in the fleet's own workgroup, with its first line as the description, so the
text in the console is the text in version control. Adding a `.sql` file
registers it; there is no list to keep in step.

## The two tables, and why there are two

`run_samples` is the measurement: one row per aggregation window, per worker,
per metric, per tag set. It is partitioned by `dt` (a projected calendar date)
and by `run_id` (an **injected** projection), so reading one run touches one
prefix and nothing else.

That choice has a consequence worth stating plainly, because it is the first
thing anyone trips over: **a query against `run_samples` with no filter on
`run_id` fails.** It does not return every run; an injected partition column
with no filter expression is an error. This is deliberate - the table
accumulates for as long as the retention allows, and an accidental scan of all
of it is paid for by whoever typed the query - but it means the question "what
runs are there" cannot be asked of the measurements at all.

`run_index` answers that question instead: one row per run, partitioned by date
only, written by the launcher's own placement record. It is also the only place
that knows what the run ASKED for, as distinct from what it measured.

Most readings of a run need both.

## Parameters

Every query takes its parameters positionally, as `?`, and every header names
them in order. The shape is almost always:

    run_id, dt_from, dt_to

`dt_from` and `dt_to` are inclusive `YYYY-MM-DD` strings in **UTC**. They are
there to prune partitions, not to filter results: the run identifier already
selects the run, and the dates tell the engine which prefixes to look in. A run
that crosses midnight UTC writes into two of them, so a range of one date is
usually right and a range of two is never wrong.

`dt` is text in a fixed ISO order, which is why `BETWEEN` works on it. The
format is pinned by the projection so that lexical and chronological order are
the same order.

Partition pruning needs a predicate on the column itself. A date derived in a
join or a subquery is not one, and a query written that way reads the whole
retention window and answers correctly, so the symptom is a bill rather than a
wrong number.

## Metrics the rows carry

`metric` holds the generator's own metric name. These are the ones the queries
use:

| `metric` | `metric_kind` | What a row means |
|---|---|---|
| `http_reqs` | counter | `sample_count` requests in this window with this tag set |
| `http_req_duration` | trend | `sample_count` observations, with `sum_ms`, `min_ms`, `max_ms` and the `buckets` ladder |
| `dropped_iterations` | counter | iterations the generator could not start |
| `checks_passed` / `checks_failed` | counter | outcomes of one named assertion |
| `vus` | gauge | population in use, in `value` |
| `connections_held` | gauge | four-tuples held at once, in `value` |
| `worker_flushes` | counter | one per worker per flush; how workers reporting is counted |

Two tag columns are load-bearing rather than descriptive, and leaving either
out of a filter changes the answer rather than widening it:

- `expected_response` separates responses the target meant to send from the
  rest. An error response is cheaper to produce than a correct one, so a target
  that begins failing fast makes an unscoped latency figure **better**. The
  figure improves while the service degrades.
- `phase` separates the ramp from the load being held. A percentile over a
  whole run includes the period during which the target was deliberately given
  less than it will get.

## What to read, in order

| File | Question it answers |
|---|---|
| `run-index.sql` | Which runs happened, and may any of them be compared? |
| `offered-vs-achieved.sql` | Did this run offer the load it was launched for? |
| `worker-skew.sql` | Was the whole fleet running for the whole run? |
| `run-summary.sql` | Headline counts, error rate and means, per phase. |
| `ladder-coverage.sql` | Is the tail measured, or does the top bucket hide it? |
| `latency-percentiles.sql` | The percentiles, as intervals. |
| `error-taxonomy.sql` | Whose failures were they? |
| `check-results.sql` | Which named assertions held? |

The order is not arbitrary. The first three decide whether the rest of the
numbers mean anything: a run with a placement shortfall, a silent worker or a
reclaimed one did not offer the load its target says, and no amount of
precision in the latency figures repairs that.

## Two properties every query here has

**It reports what it counted.** Each aggregate returns the number of windows,
workers or observations behind it. This is not decoration. A filter that
matches nothing returns NULL rather than an error - the same failure as a
threshold whose selector matched nothing, which passes - so a figure with no
count beside it cannot be distinguished from a figure computed from an empty
set.

**It does not average a percentile.** Counts and sums combine across workers
and percentiles do not: the mean of N workers' 95th percentiles is some number
between the smallest and the largest of them, and so is every other value in
that interval. Percentiles are read off the merged bucket ladder, and come back
as the interval the ladder can actually bound them to, with its width.
