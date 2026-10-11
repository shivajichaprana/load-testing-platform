-- How one run's latency distributed across the bucket ladder, and what the top bucket hides.
--
-- Parameters, in order: run_id, dt_from, dt_to.
--
-- Run this before quoting a percentile. A bucketed distribution has one
-- boundary that behaves differently from all the others: the highest one. A
-- bucket in the middle of the ladder says "between these two figures", but the
-- top bucket says only "slower than this" - it has no upper bound, so every
-- observation in it is indistinguishable from every other, however slow.
--
-- That matters in one direction only. If the top bucket holds a material share
-- of a phase's observations, the tail of that phase is UNMEASURED and any
-- percentile that falls inside it is a lower bound rather than a figure. The
-- remedy is a longer ladder, not a different query.
--
-- The cumulative share is also how to read whether the ladder is dense where
-- it needs to be: boundaries are only worth having where observations land,
-- and the ceiling the run is judged against is the one place a wide bucket
-- would decide the verdict.
WITH scan AS (
    SELECT *
    FROM run_samples
    WHERE run_id = ?
      AND dt BETWEEN ? AND ?
),
ladder AS (
    SELECT
        s.phase,
        bucket.le_ms             AS le_ms,
        sum(bucket.sample_count) AS observations
    FROM scan s
    CROSS JOIN UNNEST(s.buckets) AS t (bucket)
    WHERE s.metric = 'http_req_duration'
      AND s.expected_response
    GROUP BY s.phase, bucket.le_ms
)
SELECT
    phase,
    lag(le_ms, 1, 0.0) OVER (PARTITION BY phase ORDER BY le_ms) AS above_ms,
    le_ms                                                        AS at_or_below_ms,
    le_ms - lag(le_ms, 1, 0.0) OVER (PARTITION BY phase ORDER BY le_ms) AS width_ms,
    observations,
    round(100.0 * observations
          / nullif(sum(observations) OVER (PARTITION BY phase), 0), 3)  AS share_pct,
    round(100.0 * sum(observations) OVER (
              PARTITION BY phase
              ORDER BY le_ms
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
          ) / nullif(sum(observations) OVER (PARTITION BY phase), 0), 3) AS cumulative_pct,
    -- True for the highest boundary in the ladder. Observations here are
    -- bounded below and nothing else, so a share worth noticing means the
    -- tail was not measured.
    le_ms = max(le_ms) OVER (PARTITION BY phase)                         AS unbounded_bucket
FROM ladder
ORDER BY phase, le_ms
