-- Failed requests for one run, split by whether the target answered at all.
--
-- Parameters, in order: run_id, dt_from, dt_to.
--
-- A single error rate is the least useful figure a load test produces, because
-- it adds together two things with different owners.
--
--   A request that got a response the target did not mean to send is the
--   target's error. There is a status, and the status says what happened.
--
--   A request that got no response at all did not reach a conclusion about the
--   target. There is no status, only a generator error class - and that class
--   is as often the FLEET running out of its own resources as the target
--   refusing: a worker that has exhausted its four-tuple budget cannot open a
--   socket, and the failure is recorded against the target's name because
--   that is what the request was aimed at.
--
-- So the two are never summed here. The second group is cross-read against
-- worker-skew.sql and the connection figures: if the no-response group grows
-- while the per-worker connection count sits at the socket budget, the run
-- measured its own generator.
WITH scan AS (
    SELECT *
    FROM run_samples
    WHERE run_id = ?
      AND dt BETWEEN ? AND ?
)
SELECT
    phase,
    CASE
        WHEN status IS NOT NULL AND status <> '' THEN 'target answered'
        ELSE 'no response reached'
    END                                                              AS outcome,
    coalesce(nullif(status, ''), '(none)')                           AS status,
    coalesce(nullif(error_code, ''), '(none)')                       AS error_code,
    expected_response,
    count(DISTINCT task_id)                                          AS workers,
    sum(sample_count)                                                AS requests,
    round(100.0 * sum(sample_count)
          / nullif(sum(sum(sample_count)) OVER (PARTITION BY phase), 0), 3) AS share_of_phase_pct
FROM scan
WHERE metric = 'http_reqs'
GROUP BY
    phase,
    status,
    error_code,
    expected_response
ORDER BY phase, requests DESC
