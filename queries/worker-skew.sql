-- Per-worker contribution for one run: who offered what, and who stopped early.
--
-- Parameters, in order: run_id, dt_from, dt_to.
--
-- A fleet is only a measurement instrument while all of it is running. A
-- worker that is reclaimed, that fails, or that never reached the shared start
-- instant withdraws its share of the offered load mid-run, and nothing in the
-- TARGET's metrics distinguishes that from the target degrading: the request
-- rate falls and the latency improves, which is what a recovering service also
-- looks like. The only place the difference is visible is here, in the
-- generator's own record, which is why a run is read from both sides.
--
-- `stopped_early_seconds` is measured against the last window ANY worker
-- reported rather than against the profile's stated end, because a run that
-- ended early has a stated end too.
--
-- The worker is identified by its task identifier and not by an index. One
-- launch request places identical tasks, so every task in a request receives
-- the same overrides and no worker can be told which one it is; the index in
-- the run record is assigned afterwards, from the order the tasks came back in.
WITH scan AS (
    SELECT *
    FROM run_samples
    WHERE run_id = ?
      AND dt BETWEEN ? AND ?
),
per_worker AS (
    SELECT
        task_id,
        count(*)                                    AS windows,
        min(window_start_epoch_ms)                  AS first_ms,
        max(window_start_epoch_ms)                  AS last_ms,
        sum(sample_count)                           AS requests,
        sum(if(expected_response, 0, sample_count)) AS failed
    FROM scan
    WHERE metric = 'http_reqs'
    GROUP BY task_id
),
fleet AS (
    SELECT
        count(*)       AS reporting_workers,
        max(windows)   AS most_windows,
        min(first_ms)  AS fleet_first_ms,
        max(last_ms)   AS fleet_last_ms,
        sum(requests)  AS fleet_requests
    FROM per_worker
)
SELECT
    w.task_id,
    w.windows,
    f.most_windows,
    from_unixtime(w.first_ms / 1000.0)                                   AS first_window_utc,
    from_unixtime(w.last_ms / 1000.0)                                    AS last_window_utc,
    -- Late to the barrier. A worker placed after the start instant cannot
    -- join the ramp where its peers are, so it runs a shifted profile and its
    -- samples are tagged with a phase the rest of the fleet had left.
    (w.first_ms - f.fleet_first_ms) / 1000.0                             AS started_late_seconds,
    (f.fleet_last_ms - w.last_ms) / 1000.0                               AS stopped_early_seconds,
    w.requests,
    round(100.0 * w.requests / nullif(f.fleet_requests, 0), 2)           AS share_of_offered_pct,
    -- A uniform share is what every worker was given, so this is what an even
    -- fleet looks like. A worker materially under it either started late,
    -- stopped early, or ran out of sockets.
    round(100.0 / nullif(f.reporting_workers, 0), 2)                     AS uniform_share_pct,
    round(100.0 * w.failed / nullif(w.requests, 0), 3)                   AS error_rate_pct,
    (f.fleet_last_ms - w.last_ms) > 0                                    AS withdrew_before_the_rest
FROM per_worker w
CROSS JOIN fleet f
ORDER BY stopped_early_seconds DESC, started_late_seconds DESC, w.task_id
