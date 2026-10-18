"""Turning a run's query output into a measurement document.

A baseline is not a set of numbers; it is a set of numbers plus the conditions
under which those numbers mean anything. The conditions are the part that gets
lost, and losing them is not visible in the result: two honest latency figures
measured at different offered rates subtract cleanly, and the difference reads
like a regression.

So what is asserted here is mostly refusal. Each refusal below replaces a
document that would have been compared successfully and wrongly.
"""

from __future__ import annotations

import math
import unittest

from _support import (
    LADDER,
    bucket_for,
    capture,
    contract,
    index_row,
    measurement,
    percentile_row,
    summary_row,
)


class LadderFingerprint(unittest.TestCase):
    def test_a_ladder_names_itself_the_same_way_however_it_was_written(self) -> None:
        # A ladder written as 100 and the same ladder written as 100.0
        # aggregate alike, so they must compare alike.
        self.assertEqual(
            capture.ladder_fingerprint([100, 200, 300]),
            capture.ladder_fingerprint([100.0, 200.0, 300.0]),
        )

    def test_a_moved_boundary_changes_the_name(self) -> None:
        # The comparison refuses on this, which it can only do because the
        # fingerprint travels with the figures.
        self.assertNotEqual(
            capture.ladder_fingerprint(LADDER),
            capture.ladder_fingerprint(LADDER[:-1]),
        )

    def test_the_name_is_short_and_stable_across_calls(self) -> None:
        first = capture.ladder_fingerprint(LADDER)
        self.assertEqual(first, capture.ladder_fingerprint(LADDER))
        self.assertEqual(len(first), 12)


class QueryOutputShapes(unittest.TestCase):
    def test_both_row_wrappers_are_accepted(self) -> None:
        # Query runners disagree about this and both shapes arrive in
        # practice. Rejecting one would leave a caller with a document that
        # has no phases in it - which is not an error anywhere downstream.
        rows = [{"phase": "steady"}]
        self.assertEqual(capture.as_rows(rows, what="summary"), rows)
        self.assertEqual(capture.as_rows({"rows": rows}, what="summary"), rows)

    def test_anything_else_is_refused(self) -> None:
        for payload in ("steady", 7, None, {"data": []}, [1, 2]):
            with self.assertRaises(capture.CaptureError):
                capture.as_rows(payload, what="summary")

    def test_a_null_cell_stays_absent_rather_than_becoming_zero(self) -> None:
        # Zero requests and no measurement are different claims, and a gate
        # reads them differently: a zero error rate is a pass.
        self.assertIsNone(capture.numeric(None))
        self.assertIsNone(capture.numeric(""))
        self.assertIsNone(capture.numeric(float("nan")))
        self.assertEqual(capture.numeric("12.5"), 12.5)
        self.assertEqual(capture.numeric(0), 0.0)
        with self.assertRaises(capture.CaptureError):
            capture.numeric("fast")


class PercentileIntervals(unittest.TestCase):
    def test_a_percentile_is_stored_as_the_bracket_it_actually_is(self) -> None:
        above, at_or_below = bucket_for(250)
        entry = capture.build_percentile(
            percentile_row(at_or_below_ms=at_or_below, above_ms=above),
            ladder_top_ms=max(LADDER),
        )
        self.assertEqual(entry["above_ms"], above)
        self.assertEqual(entry["at_or_below_ms"], at_or_below)
        self.assertEqual(entry["interval_width_ms"], at_or_below - above)
        self.assertFalse(entry["unbounded_above"])

    def test_the_final_bucket_is_marked_as_having_no_upper_bound(self) -> None:
        # Stored without the flag it looks like a precise figure that happens
        # to be large, and a ceiling computed from it is arithmetic over a
        # number that was never measured.
        entry = capture.build_percentile(
            percentile_row(at_or_below_ms=max(LADDER)),
            ladder_top_ms=max(LADDER),
        )
        self.assertTrue(entry["unbounded_above"])

    def test_a_row_with_no_upper_bound_at_all_is_refused(self) -> None:
        row = percentile_row()
        row["at_or_below_ms"] = None
        with self.assertRaises(capture.CaptureError) as caught:
            capture.build_percentile(row, ladder_top_ms=max(LADDER))
        self.assertIn("only bound a verdict can be computed against", str(caught.exception))

    def test_a_backwards_bracket_is_refused_as_an_unsorted_ladder(self) -> None:
        # The cumulative sum that locates a percentile runs in boundary order,
        # so this cannot happen on a sorted ladder.
        row = percentile_row(at_or_below_ms=100.0, above_ms=250.0)
        with self.assertRaises(capture.CaptureError) as caught:
            capture.build_percentile(row, ladder_top_ms=max(LADDER))
        self.assertIn("was not sorted", str(caught.exception))

    def test_a_missing_lower_bound_reads_as_the_bottom_of_the_ladder(self) -> None:
        row = percentile_row(at_or_below_ms=1.0)
        row["above_ms"] = None
        entry = capture.build_percentile(row, ladder_top_ms=max(LADDER))
        self.assertEqual(entry["above_ms"], 0.0)


class DocumentShape(unittest.TestCase):
    def test_the_document_carries_the_conditions_a_comparison_may_refuse_on(self) -> None:
        document = measurement()
        conditions = document["conditions"]
        for field in capture.CONDITION_FIELDS:
            self.assertIn(field, conditions)
        # Carried with the figures rather than asked for again at verdict
        # time: a condition supplied separately is a condition that can be
        # supplied wrongly.
        self.assertEqual(conditions["ladder_boundaries_ms"], LADDER)
        self.assertEqual(conditions["ladder_fingerprint"], capture.ladder_fingerprint(LADDER))
        self.assertEqual(conditions["latency_ceiling_ms"], 250)
        self.assertEqual(document["schema_version"], capture.SCHEMA_VERSION)
        self.assertEqual(document["kind"], capture.DOCUMENT_KIND)

    def test_a_baseline_and_a_candidate_are_the_same_kind_of_document(self) -> None:
        # The only difference is which one has been blessed. A format that
        # distinguished them would need a conversion step at the moment of
        # promotion, and a conversion step is a place for the shapes to drift.
        baseline = measurement(role="baseline")
        candidate = measurement(role="candidate")
        self.assertEqual(baseline["role"], "baseline")
        self.assertEqual(candidate["role"], "candidate")
        del baseline["role"], candidate["role"]
        self.assertEqual(baseline, candidate)

    def test_a_missing_condition_is_refused_rather_than_assumed(self) -> None:
        for field in capture.CONDITION_FIELDS:
            overrides = {field: None}
            with self.assertRaises(capture.CaptureError) as caught:
                measurement(index_overrides=overrides)
            self.assertIn(field, str(caught.exception))

    def test_a_contract_with_no_usable_ladder_is_refused(self) -> None:
        for bad in (None, [], [100], "ladder"):
            with self.assertRaises(capture.CaptureError):
                measurement(contract_overrides={"latency_buckets_ms": bad})

    def test_a_repeated_phase_is_refused_rather_than_silently_replaced(self) -> None:
        # The summary is grouped by phase, so a repeat means two runs' output
        # was concatenated and the second set would overwrite the first.
        with self.assertRaises(capture.CaptureError) as caught:
            capture.build_document(
                index_row=index_row(),
                summary_rows=[summary_row("steady"), summary_row("steady")],
                percentile_rows=[percentile_row()],
                contract=contract(),
                role="candidate",
            )
        self.assertIn("twice", str(caught.exception))

    def test_percentiles_for_a_phase_the_summary_lacks_are_refused(self) -> None:
        # The two query outputs are from different runs, or from different
        # windows of one run; either way the figures would not be of the same
        # measurement.
        with self.assertRaises(capture.CaptureError) as caught:
            capture.build_document(
                index_row=index_row(),
                summary_rows=[summary_row("steady")],
                percentile_rows=[percentile_row("recovery")],
                contract=contract(),
                role="candidate",
            )
        self.assertIn("recovery", str(caught.exception))

    def test_a_document_with_no_phases_is_refused(self) -> None:
        # An empty document is not a measurement of nothing; it is the absence
        # of a measurement, and every selector in the policy reports unmatched
        # against it.
        with self.assertRaises(capture.CaptureError) as caught:
            capture.build_document(
                index_row=index_row(),
                summary_rows=[],
                percentile_rows=[],
                contract=contract(),
                role="candidate",
            )
        self.assertIn("absence of a measurement", str(caught.exception))

    def test_count_columns_stay_whole_numbers(self) -> None:
        entry = measurement()["phases"]["steady"]
        for field in ("workers", "windows", "requests", "failed", "dropped_iterations"):
            self.assertIsInstance(entry[field], int, field)
        self.assertIsInstance(entry["achieved_rate_per_s"], float)

    def test_the_honesty_columns_survive_into_the_document(self) -> None:
        # A figure computed from one window is arithmetically identical to one
        # computed from a thousand and means much less; a comparison that
        # cannot see the difference quotes both with the same confidence.
        entry = measurement(summary_overrides={"windows": 4, "workers": 7})["phases"]["steady"]
        self.assertEqual(entry["windows"], 4)
        self.assertEqual(entry["workers"], 7)


class BaselineAdmission(unittest.TestCase):
    def test_a_healthy_measurement_is_admitted(self) -> None:
        self.assertEqual(capture.admit_as_baseline(measurement()), [])

    def test_every_objection_is_returned_at_once(self) -> None:
        # A caller who has just finished a run wants to know everything that
        # disqualifies it instead of fixing one objection per attempt.
        document = measurement(
            index_overrides={"comparable_to_baseline": False, "shortfall": 2},
            summary_overrides={"windows": 1, "latency_observations": 50, "dropped_iterations": 9},
        )
        reasons = capture.admit_as_baseline(document)
        self.assertGreaterEqual(len(reasons), 4)
        joined = " ".join(reasons)
        self.assertIn("not comparable", joined)
        self.assertIn("worker(s) short", joined)
        self.assertIn("aggregation window(s)", joined)
        self.assertIn("latency observation(s)", joined)
        self.assertIn("dropped", joined)

    def test_a_short_run_is_refused_on_the_floors_it_misses(self) -> None:
        few_windows = measurement(summary_overrides={"windows": capture.BASELINE_MIN_WINDOWS - 1})
        self.assertTrue(
            any("aggregation window(s)" in reason for reason in capture.admit_as_baseline(few_windows))
        )
        thin = measurement(
            summary_overrides={"latency_observations": capture.BASELINE_MIN_OBSERVATIONS - 1}
        )
        # A tail percentile over a few hundred samples moves by a bucket
        # between identical runs, so a gate built on it fails on noise and
        # gets switched off.
        self.assertTrue(any("moves by a bucket" in reason for reason in capture.admit_as_baseline(thin)))

    def test_a_figure_in_the_ladders_final_bucket_cannot_be_blessed(self) -> None:
        # No ceiling can be computed from an interval that has no top.
        document = measurement(percentiles={"p95": max(LADDER)})
        reasons = capture.admit_as_baseline(document)
        self.assertTrue(any("no upper" in reason for reason in reasons))
        self.assertTrue(any("extend latency_bucket_boundaries_ms" in reason.lower() for reason in reasons))

    def test_a_dropped_iteration_disqualifies_the_whole_measurement(self) -> None:
        # The generator could not start the work it planned, so this is a
        # measurement of a smaller run than the one described.
        document = measurement(summary_overrides={"dropped_iterations": 1})
        reasons = capture.admit_as_baseline(document)
        self.assertTrue(any("dropped 1 iteration" in reason for reason in reasons))


class LadderConsistency(unittest.TestCase):
    def test_the_committed_ladder_is_strictly_increasing_and_positive(self) -> None:
        # The merge takes a cumulative sum in boundary order, so an
        # out-of-order or repeated boundary does not produce an error - it
        # produces a monotonic-looking curve that is wrong.
        self.assertGreaterEqual(len(LADDER), 2)
        self.assertTrue(all(boundary > 0 for boundary in LADDER))
        self.assertEqual(LADDER, sorted(LADDER))
        self.assertEqual(len(LADDER), len(set(LADDER)))

    def test_the_ladder_fits_one_publish_request(self) -> None:
        # Past 150 values a single window's distribution arrives as more than
        # one data point.
        self.assertLessEqual(len(LADDER), 150)

    def test_every_bucket_lookup_lands_inside_the_ladder(self) -> None:
        for value in (0.5, 1, 7, 250, 255, max(LADDER), max(LADDER) + 1):
            above, at_or_below = bucket_for(value)
            self.assertLessEqual(above, at_or_below)
            self.assertFalse(math.isnan(above))


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
