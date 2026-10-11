-- Latency percentiles for one run, read off the merged bucket ladder.
--
-- Parameters, in order: run_id, dt_from, dt_to.
--
-- This is the query the pipeline's shape exists for. A percentile cannot be
-- combined across workers: counts and sums add, but the mean of N workers'
-- 95th percentiles is simply some number between the smallest and the largest
-- of them, and so is every other value in that interval. Averaging them
-- produces a latency figure wrong by an unknown amount that reads exactly like
-- a correct one.
--
-- So each worker publishes a DISTRIBUTION over one shared ladder of
-- boundaries, the counts add - which they do, being counts - and the
-- percentile is read off the merged distribution with a cumulative sum.
--
-- What comes back is an INTERVAL, not a number. A bucketed percentile is known
-- only to the width of the bucket it falls in, so the query returns the
-- bracketing boundaries and the width between them rather than interpolating
-- inside the bucket, which would invent a precision the data does not have.
-- The ladder carries a boundary at the latency ceiling for exactly this
-- reason: the figure a run is judged against is the one place a bucket's width
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
        s.name,
        bucket.le_ms             AS le_ms,
        sum(bucket.sample_count) AS observations
    FROM scan s
    CROSS JOIN UNNEST(s.buckets) AS t (bucket)
    WHERE s.metric = 'http_req_duration'
      AND s.expected_response
    GROUP BY s.phase, s.name, bucket.le_ms
),
cumulative AS (
    SELECT
        phase,
        name,
        le_ms,
        observations,
        sum(observations) OVER (
            PARTITION BY phase, name
            ORDER BY le_ms
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS at_or_below,
        sum(observations) OVER (PARTITION BY phase, name) AS total,
        lag(le_ms, 1, 0.0) OVER (PARTITION BY phase, name ORDER BY le_ms) AS previous_le_ms
    FROM ladder
),
wanted AS (
    SELECT *
    FROM (VALUES (0.50), (0.90), (0.95), (0.99)) AS v (quantile)
),
located AS (
    SELECT
        c.phase,
        c.name,
        w.quantile,
        c.le_ms,
        c.previous_le_ms,
        c.total,
        row_number() OVER (
            PARTITION BY c.phase, c.name, w.quantile
            ORDER BY c.le_ms
        ) AS position
    FROM cumulative c
    CROSS JOIN wanted w
    WHERE c.at_or_below >= w.quantile * c.total
)
SELECT
    phase,
    name,
    format('p%d', cast(quantile * 100 AS integer)) AS percentile,
    previous_le_ms                                 AS above_ms,
    le_ms                                          AS at_or_below_ms,
    le_ms - previous_le_ms                         AS interval_width_ms,
    total                                          AS observations
FROM located
WHERE position = 1
ORDER BY phase, name, quantile
