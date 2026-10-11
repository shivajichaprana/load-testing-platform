-- Whether one run offered the load it was launched for, and achieved it.
--
-- Parameters, in order: run_id, dt_from, dt_to, run_id, dt_from, dt_to.
--
-- Three different quantities are routinely read as one, and a comparison is
-- only meaningful when all three agree:
--
--   target_rate            what the objective asked for
--   effective_offered_rate what the fleet that actually got placed could ask
--                          the target for
--   achieved_rate          what the target actually served
--
-- A shortfall between the first two is a property of the LAUNCH - placement
-- failures, a quota, a subnet out of addresses - and is invisible in the
-- target's metrics. A shortfall between the second and the third is a property
-- of the TARGET, and is the result. Reading the first gap as the second is the
-- most common way a load test reports a service as healthy at a rate it was
-- never offered.
--
-- `silent_workers` is the sharpest column: workers the launcher placed that
-- never wrote a measurement window. They were billed, they held an address,
-- and they offered nothing.
--
-- Restricted to the judged phase, because the ramp is not the load.
WITH launched AS (
    SELECT *
    FROM run_index
    WHERE run_id = ?
      AND dt BETWEEN ? AND ?
),
observed AS (
    SELECT
        count(DISTINCT task_id)                                                             AS reporting_workers,
        count(*)                                                                            AS windows,
        sum(sample_count)                                                                   AS requests,
        (max(window_start_epoch_ms + window_seconds * 1000) - min(window_start_epoch_ms)) / 1000.0 AS span_seconds
    FROM run_samples
    WHERE run_id = ?
      AND dt BETWEEN ? AND ?
      AND metric = 'http_reqs'
      AND phase = 'steady'
)
SELECT
    l.run_id,
    l.requested_workers,
    l.placed_workers,
    o.reporting_workers,
    l.placed_workers - o.reporting_workers                                           AS silent_workers,
    o.windows,
    l.target_rate,
    l.effective_offered_rate,
    round(o.requests / nullif(o.span_seconds, 0), 1)                                 AS achieved_rate_per_s,
    round(100.0 * l.effective_offered_rate / nullif(l.target_rate, 0), 2)            AS offered_pct_of_target,
    round(100.0 * (o.requests / nullif(o.span_seconds, 0))
          / nullif(l.effective_offered_rate, 0), 2)                                  AS achieved_pct_of_offered,
    l.interruptible_workers,
    cardinality(l.failures)                                                          AS placement_failures,
    -- False when the fleet was short or partly reclaimable. Either one makes a
    -- comparison against a baseline void, regardless of how good the numbers
    -- look.
    l.comparable_to_baseline
FROM launched l
CROSS JOIN observed o
