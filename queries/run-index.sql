-- Runs launched in a date range, newest first, with whether each may be compared.
--
-- Parameters, in order: dt_from, dt_to  (inclusive, 'YYYY-MM-DD', UTC).
--
-- This is the only query in the catalogue that does not name a run, and the
-- reason is the whole shape of the pipeline. The measurement table partitions
-- by run identifier so that reading one run touches one prefix, and that
-- column is an injected projection: a query against it with no run filter
-- FAILS rather than returning everything. So the question "what runs are
-- there" cannot be asked of the measurements at all, and this table - one row
-- per run, partitioned by date only - is the answer to it.
--
-- dt is text in a fixed ISO order, which is why BETWEEN works on it: the
-- format is pinned by the projection so that lexical and chronological order
-- are the same order.
SELECT
    dt                                                                      AS run_date,
    run_id,
    from_unixtime(start_epoch)                                              AS started_utc,
    scenario,
    load_model,
    regexp_extract(task_definition, ':([0-9]+)$', 1)                        AS task_definition_revision,
    requested_workers,
    placed_workers,
    shortfall,
    target_rate,
    effective_offered_rate,
    -- What the fleet could offer against what it was asked to. A shortfall is
    -- not a degradation of the target; it is the run having asked for less
    -- than its own target says, and nothing in the target's metrics says so.
    round(100.0 * (1.0 - effective_offered_rate / nullif(target_rate, 0)), 2) AS offered_shortfall_pct,
    interruptible_workers,
    cardinality(failures)                                                   AS placement_failures,
    comparable_to_baseline
FROM run_index
WHERE dt BETWEEN ? AND ?
ORDER BY start_epoch DESC
