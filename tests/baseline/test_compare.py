"""The regression comparison, and the third verdict.

A bucketed percentile comparison has three outcomes, not two. The third is
UNRESOLVED: the candidate's bucket straddles the allowed ceiling, so neither
verdict follows from the data. It is the one worth testing, because the
alternative to reporting it is a confident, stable, reproducible and unfounded
pass - and it is the outcome that most changes land in, since most changes move
a percentile by less than the width of a bucket.

Two contrasting gates run below for exactly that reason. The committed gate's
ceiling lands ON a ladder boundary, where no candidate bucket can straddle it
and every comparison resolves; a relative-only gate's ceiling lands between two
boundaries, where the straddle is real. A suite with only the first would pass
while never exercising the branch the tool exists for.
"""

from __future__ import annotations

import contextlib
import io
import json
import logging
import tempfile
import unittest
from pathlib import Path

from _support import LADDER, bucket_for, compare, measurement, policy, write_json


@contextlib.contextmanager
def silenced():
    """Keep a tool's own output off the suite's.

    `main` prints the report and configures logging on the root logger, so a
    test that invoked it without this would bury its own result in a report
    and leave the logger reconfigured for every test after it.
    """
    handlers = logging.getLogger().handlers[:]
    level = logging.getLogger().level
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            yield
    finally:
        logging.getLogger().handlers = handlers
        logging.getLogger().setLevel(level)


def judged(baseline: dict, candidate: dict, document: dict | None = None) -> dict:
    return compare.compare(
        baseline=baseline, candidate=candidate, policy=document if document else policy()
    )


def gate_of(report: dict, gate_id: str = "read-steady") -> dict:
    return next(gate for gate in report["gates"] if gate["id"] == gate_id)


class DocumentLoading(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp())

    def test_a_well_formed_document_loads(self) -> None:
        path = write_json(self.directory / "baseline.json", measurement())
        self.assertIn("phases", compare.load_document(path, what="baseline"))

    def test_a_document_of_another_schema_version_is_refused(self) -> None:
        # The figures may well be readable, but a document whose shape is not
        # the one this tool was written against can differ in which field
        # means what, and a silent misreading of a threshold is the failure
        # being avoided.
        document = measurement()
        document["schema_version"] = compare.SUPPORTED_SCHEMA + 1
        path = write_json(self.directory / "future.json", document)
        with self.assertRaises(compare.CompareError) as caught:
            compare.load_document(path, what="candidate")
        self.assertIn("silent misreading", str(caught.exception))

    def test_a_document_that_is_not_a_measurement_is_refused(self) -> None:
        for payload in ({"schema_version": 1}, {"schema_version": 1, "phases": {}}, [1, 2]):
            path = write_json(self.directory / "wrong.json", payload)
            with self.assertRaises(compare.CompareError):
                compare.load_document(path, what="candidate")

    def test_unreadable_and_unparseable_inputs_are_distinguished(self) -> None:
        missing = str(self.directory / "absent.json")
        with self.assertRaises(compare.CompareError) as caught:
            compare.load_document(missing, what="baseline")
        self.assertIn("cannot read", str(caught.exception))

        broken = self.directory / "broken.json"
        broken.write_text("{not json", encoding="utf-8")
        with self.assertRaises(compare.CompareError) as caught:
            compare.load_document(str(broken), what="baseline")
        self.assertIn("is not JSON", str(caught.exception))


class PolicyLoading(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp())

    def test_a_policy_can_be_read_without_a_yaml_parser_installed(self) -> None:
        # A gate that cannot run because a dependency is missing fails OPEN in
        # every pipeline that treats a crashing step as infrastructure flake,
        # so there is a path that needs nothing installed.
        path = write_json(self.directory / "thresholds.json", policy())
        self.assertEqual(compare.load_thresholds(path)["schema_version"], 1)

    def test_an_empty_policy_is_refused(self) -> None:
        # An empty policy passes every candidate, which is indistinguishable
        # in a pipeline from a policy that was checked and satisfied.
        for gates in ([], None, "none"):
            path = write_json(self.directory / "empty.json", policy(gates=gates))
            with self.assertRaises(compare.CompareError) as caught:
                compare.load_thresholds(path)
            self.assertIn("declares no gates", str(caught.exception))

    def test_a_policy_of_another_schema_version_is_refused(self) -> None:
        path = write_json(self.directory / "future.json", policy(schema_version=2))
        with self.assertRaises(compare.CompareError):
            compare.load_thresholds(path)


class ScenarioIdentity(unittest.TestCase):
    def test_a_path_and_a_name_denote_the_same_program(self) -> None:
        # The launcher is given a path and the policy is written with a name,
        # so one side carries a directory and a suffix and the other does not.
        for spelling in ("http-read", "http-read.js", "scenarios/http-read.js", "./scenarios/http-read.js"):
            self.assertEqual(compare.scenario_id(spelling), "http-read")
        self.assertEqual(compare.scenario_id(None), "")


class Preconditions(unittest.TestCase):
    """Reasons two documents cannot be compared at all.

    None of these is a statement about the change under test. They all say the
    candidate measured a different thing, and the only honest verdict on a
    different thing is no verdict.
    """

    def test_two_matching_runs_have_nothing_to_void_the_comparison(self) -> None:
        report = judged(measurement(), measurement(role="candidate"))
        self.assertEqual(report["void_reasons"], [])
        self.assertEqual(report["outcome"], "pass")

    def test_a_run_the_launcher_marked_not_comparable_voids_the_comparison(self) -> None:
        # A worker that withdraws mid-run takes its share of the offered load
        # with it, which looks in the target's metrics exactly like the target
        # slowing down.
        candidate = measurement(
            role="candidate",
            index_overrides={"comparable_to_baseline": False, "interruptible_workers": 3},
        )
        report = judged(measurement(), candidate)
        self.assertEqual(report["outcome"], "void")
        self.assertEqual(report["gates"], [])
        self.assertTrue(any("not comparable" in reason for reason in report["void_reasons"]))

    def test_a_baseline_marked_not_comparable_voids_every_verdict_against_it(self) -> None:
        baseline = measurement(index_overrides={"comparable_to_baseline": False})
        report = judged(baseline, measurement(role="candidate"))
        self.assertEqual(report["outcome"], "void")

    def test_a_changed_ladder_voids_the_comparison_and_says_which_boundary_moved(self) -> None:
        # A percentile is located by a cumulative sum over shared boundaries,
        # so two runs on different ladders have no percentile in common.
        candidate = measurement(
            role="candidate",
            contract_overrides={"latency_buckets_ms": [*LADDER, 75000.0]},
        )
        report = judged(measurement(), candidate)
        self.assertEqual(report["outcome"], "void")
        reason = " ".join(report["void_reasons"])
        self.assertIn("ladders differ", reason)
        # Printing two forty-element lists and leaving the reader to diff them
        # is what makes a fingerprint mismatch get overridden rather than fixed.
        self.assertIn("added 75000", reason)

    def test_an_equal_boundary_set_in_another_order_is_still_reported(self) -> None:
        described = compare.describe_ladder_change([1, 2, 3], [3, 2, 1])
        self.assertIn("order or their repeats", described)

    def test_two_different_programs_are_not_two_revisions(self) -> None:
        candidate = measurement(
            role="candidate", index_overrides={"scenario": "scenarios/http-write.js"}
        )
        report = judged(measurement(), candidate)
        self.assertEqual(report["outcome"], "void")
        self.assertTrue(any("different programs" in reason for reason in report["void_reasons"]))

    def test_a_different_offered_rate_is_a_comparison_between_two_load_levels(self) -> None:
        # Latency is a function of offered load, so this is not a comparison
        # between two revisions at all.
        candidate = measurement(role="candidate", index_overrides={"effective_offered_rate": 600.0})
        report = judged(measurement(), candidate)
        self.assertEqual(report["outcome"], "void")
        self.assertTrue(any("past the 2.00% tolerance" in reason for reason in report["void_reasons"]))

    def test_a_rate_inside_the_tolerance_does_not_void(self) -> None:
        candidate = measurement(role="candidate", index_overrides={"effective_offered_rate": 790.0})
        self.assertEqual(judged(measurement(), candidate)["outcome"], "pass")

    def test_a_missing_offered_rate_voids_rather_than_defaults(self) -> None:
        candidate = measurement(role="candidate")
        candidate["conditions"]["effective_offered_rate"] = None
        report = judged(measurement(), candidate)
        self.assertEqual(report["outcome"], "void")

    def test_the_checks_can_be_relaxed_deliberately(self) -> None:
        relaxed = policy()
        relaxed["defaults"]["require_same_scenario"] = False
        candidate = measurement(
            role="candidate", index_overrides={"scenario": "scenarios/http-write.js"}
        )
        report = judged(measurement(), candidate, relaxed)
        self.assertEqual(report["void_reasons"], [])
        # The gate is scoped to the read path, so it does not apply - and a
        # comparison that checked nothing is reported as such.
        self.assertEqual(report["outcome"], "unmatched")


class Allowances(unittest.TestCase):
    def test_the_wider_of_the_two_allowances_is_used_by_default(self) -> None:
        # Neither works across the range on its own: ten percent of a
        # three-millisecond baseline is finer than any boundary on the ladder,
        # and a flat fifty milliseconds against a two-second baseline is noise.
        rule = {"allow_abs_ms": 50, "allow_rel_pct": 15}
        self.assertEqual(compare.allowance(rule, 250.0, absolute_key="allow_abs_ms"), 50.0)
        self.assertEqual(compare.allowance(rule, 2000.0, absolute_key="allow_abs_ms"), 300.0)

    def test_the_narrower_one_can_be_asked_for(self) -> None:
        rule = {"allow_abs_ms": 50, "allow_rel_pct": 15, "combine": "narrower"}
        self.assertEqual(compare.allowance(rule, 250.0, absolute_key="allow_abs_ms"), 37.5)

    def test_a_rule_with_no_allowance_permits_nothing(self) -> None:
        self.assertEqual(compare.allowance({}, 250.0, absolute_key="allow_abs_ms"), 0.0)

    def test_an_unknown_combination_is_refused_rather_than_guessed(self) -> None:
        # Refused wherever it is written, including on a rule that carries no
        # allowance to combine: a misspelled key means the policy was not read
        # the way it was written.
        for rule in (
            {"combine": "average", "allow_abs_ms": 50, "allow_rel_pct": 15},
            {"combine": "average", "allow_abs_ms": 50},
            {"combine": "average"},
        ):
            with self.assertRaises(compare.CompareError):
                compare.allowance(rule, 250.0, absolute_key="allow_abs_ms")


class IntervalVerdicts(unittest.TestCase):
    """The three-valued verdict on one bucketed percentile."""

    def interval(self, baseline_ms: float, candidate_ms: float, allowed: float) -> dict:
        above_b, at_b = bucket_for(baseline_ms)
        above_c, at_c = bucket_for(candidate_ms)
        return compare.judge_interval(
            baseline={
                "above_ms": above_b,
                "at_or_below_ms": at_b,
                "interval_width_ms": at_b - above_b,
            },
            candidate={
                "above_ms": above_c,
                "at_or_below_ms": at_c,
                "interval_width_ms": at_c - above_c,
            },
            allowed=allowed,
        )

    def test_a_candidate_inside_the_ceiling_passes(self) -> None:
        verdict = self.interval(250, 250, 50)
        self.assertEqual(verdict["verdict"], compare.PASS)
        self.assertEqual(verdict["ceiling_ms"], 300.0)

    def test_a_candidate_whose_whole_bucket_is_past_the_ceiling_has_regressed(self) -> None:
        verdict = self.interval(250, 400, 50)
        self.assertEqual(verdict["verdict"], compare.REGRESSED)

    def test_a_ceiling_on_a_ladder_boundary_always_resolves(self) -> None:
        # The committed read-path gate works out this way, and it is why that
        # gate never reports unresolved: the ceiling is 300ms, which is a
        # boundary, so no bucket can straddle it.
        above, at_or_below = bucket_for(250)
        self.assertIn(at_or_below + 50, LADDER)
        for candidate_ms in (10, 100, 250, 290, 300, 310, 400, 1000):
            self.assertIn(
                self.interval(250, candidate_ms, 50)["verdict"],
                (compare.PASS, compare.REGRESSED),
                candidate_ms,
            )
        self.assertEqual(above, 200.0)

    def test_a_ceiling_between_two_boundaries_can_leave_the_verdict_unresolved(self) -> None:
        # A relative-only allowance of 15% on a 250ms baseline puts the
        # ceiling at 287.5ms, inside the 250-to-300 bucket, so a candidate
        # there may be either side of it.
        verdict = self.interval(250, 300, 37.5)
        self.assertEqual(verdict["verdict"], compare.UNRESOLVED)
        self.assertEqual(verdict["ceiling_ms"], 287.5)
        # The remedy is printed, because the figure cannot be resolved by
        # tightening the allowance - only by adding a boundary.
        self.assertIn("Add a boundary at 287.5", verdict["remedy"])
        self.assertIn("recapture", verdict["remedy"])

    def test_the_smallest_increase_the_gate_can_catch_is_published(self) -> None:
        # Stated rather than hidden: an increase below this floor may be real
        # and may still report as a pass, and no narrower allowance changes
        # that.
        verdict = self.interval(250, 250, 50)
        self.assertEqual(verdict["resolution_floor_ms"], 50 + 50 + 50)

    def test_a_candidate_in_the_final_bucket_carries_the_reason_it_cannot_pass(self) -> None:
        above, at_or_below = bucket_for(max(LADDER))
        verdict = compare.judge_interval(
            baseline={"above_ms": 200.0, "at_or_below_ms": 250.0, "interval_width_ms": 50.0},
            candidate={
                "above_ms": above,
                "at_or_below_ms": at_or_below,
                "interval_width_ms": 0.0,
                "unbounded_above": True,
            },
            allowed=50,
        )
        self.assertEqual(verdict["verdict"], compare.REGRESSED)
        self.assertIn("no upper bound", verdict["note"])


class ScalarVerdicts(unittest.TestCase):
    """Figures that combine exactly across the fleet, so carry no interval."""

    def test_a_figure_within_its_allowance_passes(self) -> None:
        verdict = compare.judge_scalar(
            candidate=0.05, baseline=0.0, rule={"allow_abs": 0.1}, label="error_rate_pct"
        )
        self.assertEqual(verdict["verdict"], compare.PASS)
        self.assertEqual(verdict["bound"], 0.1)

    def test_a_figure_past_its_allowance_has_regressed(self) -> None:
        verdict = compare.judge_scalar(
            candidate=0.2, baseline=0.0, rule={"allow_abs": 0.1}, label="error_rate_pct"
        )
        self.assertEqual(verdict["verdict"], compare.REGRESSED)
        self.assertIn("the gate requires at or below 0.1", verdict["detail"])

    def test_a_figure_where_lower_is_worse_is_bounded_from_below(self) -> None:
        # A change that holds its latency by serving less is a regression, and
        # a gate reading only latency passes it.
        rule = {"direction": "not_below", "allow_rel_pct": 3}
        self.assertEqual(
            compare.judge_scalar(candidate=790.0, baseline=800.0, rule=rule, label="rate")["verdict"],
            compare.PASS,
        )
        worse = compare.judge_scalar(candidate=700.0, baseline=800.0, rule=rule, label="rate")
        self.assertEqual(worse["verdict"], compare.REGRESSED)
        self.assertEqual(worse["bound"], 776.0)

    def test_a_hard_limit_ignores_the_baseline_entirely(self) -> None:
        # A run that dropped iterations did not offer the rate it reports, so
        # its latency figures describe a smaller run - and this is the gate
        # that stops that being read as an improvement.
        rule = {"max_abs": 0}
        self.assertEqual(
            compare.judge_scalar(candidate=0, baseline=0, rule=rule, label="dropped")["verdict"],
            compare.PASS,
        )
        self.assertEqual(
            compare.judge_scalar(candidate=4, baseline=0, rule=rule, label="dropped")["verdict"],
            compare.REGRESSED,
        )

    def test_an_absent_figure_is_unresolved_and_never_a_pass(self) -> None:
        # A missing figure reads like a zero to anything that defaults it, and
        # a zero error rate is a pass.
        for candidate, baseline in ((None, 0.0), (0.0, None)):
            verdict = compare.judge_scalar(
                candidate=candidate, baseline=baseline, rule={"allow_abs": 0.1}, label="error_rate_pct"
            )
            self.assertEqual(verdict["verdict"], compare.UNRESOLVED)
            self.assertIn("nothing to compare", verdict["detail"])

        unchecked = compare.judge_scalar(
            candidate=None, baseline=0, rule={"max_abs": 0}, label="dropped"
        )
        self.assertEqual(unchecked["verdict"], compare.UNRESOLVED)
        self.assertIn("unchecked", unchecked["detail"])

    def test_an_unknown_direction_is_refused(self) -> None:
        with self.assertRaises(compare.CompareError):
            compare.judge_scalar(
                candidate=1.0, baseline=1.0, rule={"direction": "sideways"}, label="rate"
            )


class SeriesSelection(unittest.TestCase):
    def test_a_phase_with_one_series_needs_no_selector(self) -> None:
        entry = measurement()["phases"]["steady"]
        series, problem = compare.series_for(entry, {})
        self.assertEqual(series, "read listing")
        self.assertIsNone(problem)

    def test_a_phase_with_several_series_and_no_selector_is_an_error(self) -> None:
        # Picking one of them would make the gate's subject depend on the
        # order the query returned its rows.
        entry = measurement()["phases"]["steady"]
        entry["latency"]["search items"] = dict(entry["latency"]["read listing"])
        series, problem = compare.series_for(entry, {})
        self.assertIsNone(series)
        self.assertIn("Add `series:`", problem)

    def test_a_named_series_is_looked_up_and_its_absence_is_reported(self) -> None:
        entry = measurement()["phases"]["steady"]
        self.assertEqual(compare.series_for(entry, {"series": "read listing"})[0], "read listing")
        series, problem = compare.series_for(entry, {"series": "write item"})
        self.assertIsNone(series)
        self.assertIn("no latency series named", problem)

    def test_a_phase_with_no_series_at_all_is_reported(self) -> None:
        entry = {"latency": {}}
        self.assertIn("no latency series at all", compare.series_for(entry, {})[1])


class GateEvaluation(unittest.TestCase):
    def test_a_matching_gate_reports_one_verdict_per_rule(self) -> None:
        report = judged(measurement(), measurement(role="candidate"))
        gate = gate_of(report)
        self.assertEqual(gate["verdict"], compare.PASS)
        self.assertEqual(
            sorted(gate["checks"]),
            ["achieved_rate_per_s", "dropped_iterations", "error_rate_pct", "p95"],
        )

    def test_a_gate_for_another_scenario_is_not_applicable_rather_than_unmatched(self) -> None:
        # The policy holds gates for every scenario the platform runs and one
        # run exercises one of them, so treating the rest as unmatched would
        # fail every comparison on gates never meant to apply.
        document = policy()
        document["gates"].append(
            {
                "id": "write-steady",
                "select": {"scenario": "http-write", "phase": "steady"},
                "rules": {"error_rate_pct": {"allow_abs": 0.2}},
            }
        )
        report = judged(measurement(), measurement(role="candidate"), document)
        self.assertEqual(gate_of(report, "write-steady")["verdict"], compare.SKIPPED)
        self.assertEqual(report["outcome"], "pass")

    def test_a_renamed_phase_fails_rather_than_switching_its_gate_off(self) -> None:
        candidate = measurement(role="candidate", phase="hold")
        report = judged(measurement(), candidate)
        gate = gate_of(report)
        self.assertEqual(gate["verdict"], compare.UNMATCHED)
        self.assertIn("report a pass", gate["detail"])
        self.assertEqual(report["outcome"], "unmatched")

    def test_a_selector_naming_no_phase_identifies_no_figures(self) -> None:
        document = policy()
        document["gates"][0]["select"] = {"scenario": "http-read"}
        report = judged(measurement(), measurement(role="candidate"), document)
        self.assertEqual(gate_of(report)["verdict"], compare.UNMATCHED)

    def test_a_gate_with_no_rules_is_unmatched_rather_than_a_pass(self) -> None:
        document = policy()
        document["gates"][0]["rules"] = {}
        report = judged(measurement(), measurement(role="candidate"), document)
        self.assertEqual(gate_of(report)["verdict"], compare.UNMATCHED)
        self.assertIn("would pass", gate_of(report)["detail"])

    def test_too_few_windows_leaves_the_gate_unresolved(self) -> None:
        # The figures exist; the averaging their decimal places imply does not.
        candidate = measurement(role="candidate", summary_overrides={"windows": 2})
        report = judged(measurement(), candidate)
        self.assertEqual(gate_of(report)["verdict"], compare.UNRESOLVED)
        self.assertIn("aggregation window(s)", gate_of(report)["detail"])

    def test_too_few_latency_observations_leaves_the_percentiles_unresolved(self) -> None:
        candidate = measurement(role="candidate", summary_overrides={"latency_observations": 500})
        report = judged(measurement(), candidate)
        gate = gate_of(report)
        self.assertEqual(gate["checks"]["percentile"]["verdict"], compare.UNRESOLVED)
        # The scalars still resolve: counts and sums combine exactly, so they
        # carry none of the percentiles' uncertainty.
        self.assertEqual(gate["checks"]["error_rate_pct"]["verdict"], compare.PASS)

    def test_a_baseline_percentile_with_no_upper_bound_cannot_be_judged_against(self) -> None:
        baseline = measurement(percentiles={"p95": max(LADDER)})
        candidate = measurement(role="candidate", percentiles={"p95": 250.0})
        report = judged(baseline, candidate)
        check = gate_of(report)["checks"]["p95"]
        self.assertEqual(check["verdict"], compare.UNRESOLVED)
        self.assertIn("Extend the ladder", check["detail"])

    def test_a_percentile_absent_from_one_document_is_unmatched(self) -> None:
        baseline = measurement(percentiles={"p95": 250.0})
        candidate = measurement(role="candidate", percentiles={"p50": 50.0})
        report = judged(baseline, candidate)
        # The series carries p50 on one side and p95 on the other, so the gate
        # has no common figure to judge.
        self.assertIn(gate_of(report)["verdict"], (compare.UNMATCHED, compare.UNRESOLVED))

    def test_a_regression_in_any_rule_decides_the_whole_gate(self) -> None:
        candidate = measurement(
            role="candidate", summary_overrides={"error_rate_pct": 0.9}
        )
        report = judged(measurement(), candidate)
        self.assertEqual(gate_of(report)["verdict"], compare.REGRESSED)
        self.assertEqual(report["outcome"], "regressed")

    def test_a_regression_outranks_an_unresolved_check_in_the_same_gate(self) -> None:
        candidate = measurement(
            role="candidate",
            summary_overrides={"error_rate_pct": 0.9, "latency_observations": 500},
        )
        report = judged(measurement(), candidate)
        self.assertEqual(gate_of(report)["verdict"], compare.REGRESSED)

    def test_a_policy_with_no_applicable_gate_is_reported_rather_than_passed(self) -> None:
        document = policy()
        document["gates"][0]["select"]["scenario"] = "user-journey"
        report = judged(measurement(), measurement(role="candidate"), document)
        self.assertEqual(report["outcome"], "unmatched")
        self.assertIn("checked nothing", report["detail"])


class ExitCodes(unittest.TestCase):
    def test_each_outcome_has_its_own_code(self) -> None:
        defaults = policy()["defaults"]
        for outcome, code in (
            ("pass", compare.EXIT_PASS),
            ("regressed", compare.EXIT_REGRESSED),
            ("unresolved", compare.EXIT_NOT_JUDGED),
            ("unmatched", compare.EXIT_NOT_JUDGED),
            ("void", compare.EXIT_VOID),
        ):
            self.assertEqual(compare.exit_code({"outcome": outcome}, defaults), code, outcome)

    def test_an_unresolved_verdict_fails_by_default(self) -> None:
        # The alternative silently admits every change too small for the
        # ladder to see, which is most of them.
        self.assertEqual(compare.exit_code({"outcome": "unresolved"}, {}), compare.EXIT_NOT_JUDGED)

    def test_the_failure_direction_can_be_changed_deliberately(self) -> None:
        self.assertEqual(
            compare.exit_code({"outcome": "unresolved"}, {"on_unresolved": "pass"}),
            compare.EXIT_PASS,
        )
        self.assertEqual(
            compare.exit_code({"outcome": "unmatched"}, {"on_unmatched_selector": "pass"}),
            compare.EXIT_PASS,
        )


class Rendering(unittest.TestCase):
    def test_the_text_report_names_the_runs_the_gates_and_the_outcome(self) -> None:
        report = judged(measurement(), measurement(role="candidate"))
        rendered = compare.render_text(report)
        self.assertIn("read-steady", rendered)
        self.assertIn("pass", rendered)
        self.assertIn(report["candidate_run"], rendered)

    def test_a_void_report_renders_its_reasons(self) -> None:
        candidate = measurement(role="candidate", index_overrides={"comparable_to_baseline": False})
        rendered = compare.render_text(judged(measurement(), candidate))
        self.assertIn("not comparable", rendered)


class CommandLine(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp())
        self.baseline = write_json(self.directory / "baseline.json", measurement())
        self.thresholds = write_json(self.directory / "thresholds.json", policy())

    def run_against(self, candidate: dict, *extra: str) -> tuple[int, Path]:
        path = write_json(self.directory / "candidate.json", candidate)
        out = self.directory / "report.json"
        # The report is written to standard output as well as to the file, and
        # a suite that let it through would bury its own result. The file is
        # what is asserted on, which is also what a pipeline step reads.
        with silenced():
            code = compare.main(
                [
                    "--baseline",
                    self.baseline,
                    "--candidate",
                    path,
                    "--thresholds",
                    self.thresholds,
                    "--format",
                    "json",
                    "--out",
                    str(out),
                    *extra,
                ]
            )
        return code, out

    def test_a_clean_candidate_exits_zero_and_writes_a_parseable_report(self) -> None:
        code, out = self.run_against(measurement(role="candidate"))
        self.assertEqual(code, compare.EXIT_PASS)
        written = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(written["outcome"], "pass")

    def test_a_regression_exits_one(self) -> None:
        code, _ = self.run_against(
            measurement(role="candidate", summary_overrides={"dropped_iterations": 3})
        )
        self.assertEqual(code, compare.EXIT_REGRESSED)

    def test_an_incomparable_run_exits_with_the_void_code(self) -> None:
        code, _ = self.run_against(
            measurement(role="candidate", index_overrides={"comparable_to_baseline": False})
        )
        self.assertEqual(code, compare.EXIT_VOID)

    def test_bad_input_exits_with_the_usage_code_rather_than_a_traceback(self) -> None:
        with silenced():
            code = compare.main(
                [
                    "--baseline",
                    str(self.directory / "absent.json"),
                    "--candidate",
                    self.baseline,
                    "--thresholds",
                    self.thresholds,
                ]
            )
        self.assertEqual(code, compare.EXIT_USAGE)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
