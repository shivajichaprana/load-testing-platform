-- Headline figures for one run, per phase, combined across every worker.
--
-- Parameters, in order: run_id, dt_from, dt_to.
--
-- Everything here is a quantity that COMBINES across workers: counts add and
-- sums add, so a request total, an error rate and a mean are all exact over
-- the fleet. Percentiles are absent on purpose - the mean of twenty workers'
-- 95th percentiles is not the fleet's 95th percentile and bears no stated
-- relation to it, so they are read off the merged ladder in
-- latency-percentiles.sql instead.
--
-- Two columns are honesty rather than measurement. `windows` is the number of
-- aggregation windows the figures were computed from and `workers` is how many
-- distinct workers contributed: a figure computed from nothing is returned as
-- NULL rather than as an error, which is the same failure as a threshold whose
-- selector matched nothing, so every query here reports what it counted.
WITH scan AS (
    SELECT *
    FROM run_samples
    WHERE run_id = ?
      AND dt BETWEEN ? AND ?
),
requests AS (
    SELECT
        phase,
        count(*)                                           AS windows,
        count(DISTINCT task_id)                            AS workers,
        sum(sample_count)                                  AS requests,
        sum(if(expected_response, 0, sample_count))         AS failed,
        min(window_start_epoch_ms)                         AS first_window_ms,
        max(window_start_epoch_ms + window_seconds * 1000) AS last_window_ms
    FROM scan
    WHERE metric = 'http_reqs'
    GROUP BY phase
),
durations AS (
    -- Scoped to responses the target MEANT to send. An error response is
    -- cheaper to produce than a correct one, so a target that starts failing
    -- fast makes the unscoped mean BETTER - the figure improves while the
    -- service degrades, and a gate reading it passes the release that broke it.
    SELECT
        phase,
        sum(sample_count) AS observations,
        sum(sum_ms)       AS total_ms,
        min(min_ms)       AS fastest_ms,
        max(max_ms)       AS slowest_ms
    FROM scan
    WHERE metric = 'http_req_duration'
      AND expected_response
    GROUP BY phase
),
drops AS (
    -- The generator's own confession. A run that could not start the
    -- iterations it planned did not offer the rate it reports, so the
    -- comparison it was launched for is void whatever the target did.
    SELECT
        phase,
        sum(sample_count) AS dropped_iterations
    FROM scan
    WHERE metric = 'dropped_iterations'
    GROUP BY phase
)
SELECT
    r.phase,
    r.workers,
    r.windows,
    r.requests,
    r.failed,
    round(100.0 * r.failed / nullif(r.requests, 0), 3)                      AS error_rate_pct,
    coalesce(d.dropped_iterations, 0)                                       AS dropped_iterations,
    -- Measured from the span the windows actually cover, not from the
    -- profile's stated duration: a phase that ended early because the fleet
    -- was reclaimed still has a stated duration.
    (r.last_window_ms - r.first_window_ms) / 1000.0                         AS observed_seconds,
    round(r.requests / nullif((r.last_window_ms - r.first_window_ms) / 1000.0, 0), 1) AS achieved_rate_per_s,
    t.observations                                                          AS latency_observations,
    round(t.total_ms / nullif(t.observations, 0), 2)                        AS mean_ms,
    t.fastest_ms,
    -- The only exact tail figure the pipeline has. Everything between this and
    -- the mean is known only to the width of a bucket.
    t.slowest_ms
FROM requests r
LEFT JOIN durations t ON t.phase = r.phase
LEFT JOIN drops d ON d.phase = r.phase
ORDER BY r.phase
