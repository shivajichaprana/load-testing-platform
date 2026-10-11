-- Named assertion outcomes for one run, per phase, worst pass rate first.
--
-- Parameters, in order: run_id, dt_from, dt_to.
--
-- Read this as evidence and not as a verdict. A check RECORDS a result; it
-- does not fail a run. The exit status of a run is decided by its thresholds,
-- so a scenario full of checks and no thresholds exits zero with every
-- assertion in it failing - and a gate reading that exit status reports the
-- release as clean. A pass rate below one here is therefore only binding where
-- a threshold was scoped to that same name and phase.
--
-- The phase column is the reason the rate is not computed over the whole run.
-- A ramp is a period during which the target is deliberately being given less
-- than it will get, and an assertion that fails only during the ramp is a
-- different fact from one that fails while the load is held.
WITH scan AS (
    SELECT *
    FROM run_samples
    WHERE run_id = ?
      AND dt BETWEEN ? AND ?
),
outcomes AS (
    SELECT
        phase,
        check_name,
        count(DISTINCT task_id)                                 AS workers,
        sum(if(metric = 'checks_passed', sample_count, 0))      AS passed,
        sum(if(metric = 'checks_failed', sample_count, 0))      AS failed
    FROM scan
    WHERE metric = 'checks_passed'
       OR metric = 'checks_failed'
    GROUP BY phase, check_name
)
SELECT
    phase,
    check_name,
    workers,
    passed,
    failed,
    passed + failed                                             AS recorded,
    round(100.0 * passed / nullif(passed + failed, 0), 3)       AS pass_rate_pct
FROM outcomes
ORDER BY pass_rate_pct ASC, phase, check_name
