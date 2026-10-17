#!/usr/bin/env python3
"""Turn one run's query output into a measurement document.

A baseline is not a set of numbers. It is a set of numbers plus the conditions
under which those numbers mean anything, and the conditions are the part that
gets lost. Two runs of the same scenario at different offered rates produce two
honest latency figures that cannot be subtracted from one another; so do two
runs aggregated over different bucket ladders, and so do a full fleet and a
fleet that was three workers short. A document that records only the figures
invites exactly that subtraction, and the result reads like a regression.

So this tool writes the figures together with the offered rate, the placed
worker count, the scenario, the result contract's version and a fingerprint of
the latency ladder. The comparison refuses to run when any of those differ,
which it can only do because they travel with the measurement.

A baseline and a candidate are the SAME kind of document. The only difference
between them is which one has been blessed - the baseline is the one that was
committed - and that is deliberate: a format that distinguished them would need
a conversion step at the moment of promotion, and a conversion step is a place
for the two shapes to drift. What differs is the admission rules, selected with
--role: a candidate may carry anything that was measured, while a baseline has
to be clean, because every later verdict is quoted against it.

Percentiles are recorded as INTERVALS. The pipeline reads them off a merged
bucket ladder, so a percentile is known only to the width of the bucket it
falls in; storing the upper boundary alone as "the p95" turns a bracket into a
point and loses the one fact a comparison needs to stay honest. Each entry
therefore carries the bracketing boundaries and their width, and the comparison
does interval arithmetic with them rather than subtraction.

Nothing here touches the cloud. The inputs are the JSON output of the committed
queries and the run's index row, all of which the caller already has, and the
output is a file intended to be reviewed and committed:

    capture.py --role baseline \\
      --index-row index.json --summary summary.json \\
      --percentiles percentiles.json --contract contract.json \\
      --out baseline/profiles/http-read.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import math
import sys
from typing import Any

LOG = logging.getLogger("capture")

SCHEMA_VERSION = 1
DOCUMENT_KIND = "load-measurement"

# Conditions copied out of the run's index row. Each one is a reason a
# comparison can be void, which is why the document carries them rather than
# the comparison asking for them again at verdict time: a condition supplied
# separately from the figures is a condition that can be supplied wrongly.
CONDITION_FIELDS = (
    "requested_workers",
    "placed_workers",
    "shortfall",
    "interruptible_workers",
    "target_rate",
    "rate_per_worker",
    "effective_offered_rate",
    "comparable_to_baseline",
)

RUN_FIELDS = ("run_id", "start_epoch", "scenario", "cluster", "task_definition", "load_model")

# Summary columns carried through from run-summary.sql. The two honesty columns
# - `windows` and `workers` - are included on purpose: a figure computed from
# one window is arithmetically identical to a figure computed from a thousand
# and means much less, and a comparison that cannot see the difference will
# quote both with the same confidence.
SUMMARY_FIELDS = (
    "workers",
    "windows",
    "requests",
    "failed",
    "error_rate_pct",
    "dropped_iterations",
    "observed_seconds",
    "achieved_rate_per_s",
    "latency_observations",
    "mean_ms",
    "fastest_ms",
    "slowest_ms",
)

# A baseline has to be stronger than a candidate, because it is quoted in every
# later verdict. These are the admission rules only the baseline role applies.
BASELINE_MIN_OBSERVATIONS = 1000
BASELINE_MIN_WINDOWS = 3


class CaptureError(RuntimeError):
    """Raised when the inputs cannot be turned into a document worth comparing."""


def ladder_fingerprint(boundaries: list[float]) -> str:
    """A short, stable name for one ladder.

    Two runs aggregated over different ladders are not comparable at any
    percentile: the merge is a cumulative sum over shared boundaries, and
    boundaries that differ produce two curves that cannot be read against each
    other. The comparison needs to detect that, and comparing two boundary
    lists element by element in a report is unreadable - so the list is
    reduced to a name, and the full list is carried alongside it for the case
    where a reader needs to see which boundary moved.

    Canonicalised through repr of a float list rather than the raw JSON text,
    so that a ladder written as 100 and the same ladder written as 100.0
    fingerprint alike. They aggregate alike, so they must compare alike.
    """
    canonical = json.dumps([float(b) for b in boundaries], separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:12]


def as_rows(payload: Any, *, what: str) -> list[dict[str, Any]]:
    """Accept either a bare list of rows or a wrapper with a `rows` key.

    Query runners disagree about this and both shapes arrive in practice. The
    alternative to accepting both is a caller who pipes the wrong one and gets
    a document with no phases in it, which is not an error anywhere downstream:
    a comparison against an empty document matches no selector, and an
    unmatched selector is the failure mode this project treats as a real one.
    """
    if isinstance(payload, dict) and "rows" in payload:
        payload = payload["rows"]
    if not isinstance(payload, list):
        raise CaptureError(f"{what} must be a list of rows, or an object with a 'rows' key.")
    for row in payload:
        if not isinstance(row, dict):
            raise CaptureError(f"{what} contains a {type(row).__name__} where a row was expected.")
    return payload


def numeric(value: Any) -> float | None:
    """Coerce a query cell to a float, or None.

    NULL is a legitimate answer from every query here - run-summary.sql returns
    it for a figure computed from nothing - and it has to survive as None
    rather than becoming 0.0, because zero requests and no measurement are
    different claims and a gate reads them differently.
    """
    if value is None or value == "":
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError) as error:
        raise CaptureError(f"{value!r} is not a number: {error}") from error
    if math.isnan(parsed):
        return None
    return parsed


def build_percentile(row: dict[str, Any], *, ladder_top_ms: float) -> dict[str, Any]:
    """One percentile, as the bracket it actually is.

    `unbounded_above` is the entry that matters. The ladder's largest boundary
    is the last thing it can distinguish, so a percentile located in the final
    bucket is known only to be somewhere above the previous boundary - there is
    no upper bound on it at all. Stored without that flag it looks like a
    precise figure that happens to be large, and a ceiling computed from it is
    arithmetic over a number that was never measured.
    """
    above = numeric(row.get("above_ms"))
    at_or_below = numeric(row.get("at_or_below_ms"))
    if at_or_below is None:
        raise CaptureError(
            f"percentile row {row.get('percentile')!r} for phase {row.get('phase')!r} has no "
            "at_or_below_ms, which is the only bound a verdict can be computed against."
        )
    if above is None:
        above = 0.0
    if at_or_below < above:
        raise CaptureError(
            f"percentile row {row.get('percentile')!r} brackets backwards "
            f"({above} to {at_or_below}); the cumulative sum that locates it runs in boundary "
            "order, so this means the ladder it was read off was not sorted."
        )
    observations = numeric(row.get("observations"))
    return {
        "above_ms": above,
        "at_or_below_ms": at_or_below,
        "interval_width_ms": at_or_below - above,
        "observations": None if observations is None else int(observations),
        "unbounded_above": at_or_below >= ladder_top_ms,
    }


def build_document(
    *,
    index_row: dict[str, Any],
    summary_rows: list[dict[str, Any]],
    percentile_rows: list[dict[str, Any]],
    contract: dict[str, Any],
    role: str,
) -> dict[str, Any]:
    boundaries = contract.get("latency_buckets_ms")
    if not isinstance(boundaries, list) or len(boundaries) < 2:
        raise CaptureError(
            "the contract carries no usable latency_buckets_ms. Without the ladder the document "
            "cannot record which boundaries its percentiles were read off, and a comparison "
            "that cannot check the ladder is comparing two unrelated curves."
        )
    ladder = [float(b) for b in boundaries]
    ladder_top = max(ladder)

    missing = [field for field in CONDITION_FIELDS if index_row.get(field) is None]
    if missing:
        raise CaptureError(
            f"the index row is missing {', '.join(missing)}. Every one of them is a condition a "
            "comparison is allowed to refuse on, and a document without them can only be "
            "compared by assuming the conditions matched."
        )

    document: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "kind": DOCUMENT_KIND,
        "role": role,
        "run": {field: index_row.get(field) for field in RUN_FIELDS},
        "conditions": {field: index_row[field] for field in CONDITION_FIELDS},
        "phases": {},
    }
    document["conditions"]["contract_schema_version"] = contract.get("schema_version")
    document["conditions"]["latency_ceiling_ms"] = numeric(contract.get("latency_ceiling_ms"))
    document["conditions"]["ladder_fingerprint"] = ladder_fingerprint(ladder)
    document["conditions"]["ladder_boundaries_ms"] = ladder

    for row in summary_rows:
        phase = row.get("phase")
        if phase is None:
            raise CaptureError("a summary row has no phase; the figures cannot be placed.")
        phase = str(phase)
        if phase in document["phases"]:
            raise CaptureError(
                f"phase {phase!r} appears twice in the summary. The summary is grouped by phase, "
                "so a repeat means two runs' output was concatenated - and the second set would "
                "silently replace the first."
            )
        entry: dict[str, Any] = {field: numeric(row.get(field)) for field in SUMMARY_FIELDS}
        for count_field in ("workers", "windows", "requests", "failed", "dropped_iterations"):
            if entry[count_field] is not None:
                entry[count_field] = int(entry[count_field])
        entry["latency"] = {}
        document["phases"][phase] = entry

    for row in percentile_rows:
        phase = str(row.get("phase")) if row.get("phase") is not None else None
        label = row.get("percentile")
        if phase is None or not label:
            raise CaptureError(
                "a percentile row is missing its phase or its percentile label; neither can be "
                "inferred, and a row placed under a guess is worse than a row dropped."
            )
        if phase not in document["phases"]:
            raise CaptureError(
                f"percentiles arrived for phase {phase!r}, which the summary does not contain. "
                "The two query outputs are from different runs, or from different time windows "
                "of one run - either way the figures in this document would not be of the same "
                "measurement."
            )
        series = str(row.get("name") or "")
        bucket = document["phases"][phase]["latency"].setdefault(series, {})
        if label in bucket:
            raise CaptureError(
                f"percentile {label} appears twice for phase {phase!r} series {series!r}."
            )
        bucket[str(label)] = build_percentile(row, ladder_top_ms=ladder_top)

    if not document["phases"]:
        raise CaptureError(
            "no phases were captured. An empty document is not a measurement of nothing, it is "
            "the absence of a measurement, and every selector in the policy would report as "
            "unmatched against it."
        )
    return document


def admit_as_baseline(document: dict[str, Any]) -> list[str]:
    """Why this measurement is not fit to be quoted in later verdicts.

    Returned rather than raised, one line per reason, because a caller who has
    just finished a run wants to know everything that disqualifies it instead
    of fixing one objection per attempt.
    """
    reasons: list[str] = []
    conditions = document["conditions"]

    if not conditions.get("comparable_to_baseline"):
        reasons.append(
            "the launcher marked the run not comparable: "
            f"{conditions.get('shortfall')} worker(s) short and "
            f"{conditions.get('interruptible_workers')} on reclaimable capacity. A worker that "
            "withdraws mid-run takes its share of the offered load with it, which looks in the "
            "target's metrics exactly like the target slowing down."
        )
    if int(conditions.get("shortfall") or 0) > 0:
        reasons.append(
            f"the fleet was {conditions['shortfall']} worker(s) short of the "
            f"{conditions.get('requested_workers')} requested, so the run did not offer the rate "
            "this document reports as its offered rate."
        )

    for phase, entry in sorted(document["phases"].items()):
        windows = entry.get("windows")
        if windows is not None and windows < BASELINE_MIN_WINDOWS:
            reasons.append(
                f"phase {phase!r} was computed from {windows} aggregation window(s), below the "
                f"{BASELINE_MIN_WINDOWS} this tool will bless. A figure from one window is a "
                "sample of one and carries none of the averaging its decimal places imply."
            )
        observations = entry.get("latency_observations")
        if observations is not None and observations < BASELINE_MIN_OBSERVATIONS:
            reasons.append(
                f"phase {phase!r} has {int(observations)} latency observation(s), below the "
                f"{BASELINE_MIN_OBSERVATIONS} floor. A tail percentile over a few hundred "
                "samples moves by a bucket between identical runs, so a gate built on it fails "
                "on noise and gets switched off."
            )
        if (entry.get("dropped_iterations") or 0) > 0:
            reasons.append(
                f"phase {phase!r} dropped {int(entry['dropped_iterations'])} iteration(s): the "
                "generator could not start the work it planned, so this is a measurement of a "
                "smaller run than the one described."
            )
        for series, percentiles in sorted(entry["latency"].items()):
            for label, value in sorted(percentiles.items()):
                if value["unbounded_above"]:
                    reasons.append(
                        f"phase {phase!r} series {series or '(unnamed)'} has {label} in the "
                        f"ladder's final bucket, above {value['above_ms']}ms with no upper "
                        "bound. No ceiling can be computed from an interval that has no top; "
                        "extend latency_bucket_boundaries_ms past the figure and measure again."
                    )
    return reasons


def load_json(path: str, *, what: str) -> Any:
    try:
        raw = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
    except OSError as error:
        raise CaptureError(f"cannot read {what} from {path}: {error}") from error
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise CaptureError(f"{what} at {path} is not JSON: {error}") from error


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--index-row",
        required=True,
        help="The run's row in the run index, as JSON. Accepts the publisher's output envelope "
        "or the row on its own.",
    )
    parser.add_argument(
        "--summary", required=True, help="Output of run-summary.sql for this run, as JSON rows."
    )
    parser.add_argument(
        "--percentiles",
        required=True,
        help="Output of latency-percentiles.sql for this run, as JSON rows.",
    )
    parser.add_argument(
        "--contract",
        required=True,
        help="The result contract the run was aggregated under. The ladder is read from it, and "
        "the ladder is what decides whether two runs are comparable at all.",
    )
    parser.add_argument(
        "--role",
        choices=("baseline", "candidate"),
        default="candidate",
        help="A baseline has to pass admission rules a candidate does not, because it is quoted "
        "in every verdict taken against it. Default: candidate.",
    )
    parser.add_argument("--out", help="Write the document here instead of standard output.")
    parser.add_argument(
        "--allow-unfit-baseline",
        action="store_true",
        help="Write a baseline that failed admission, recording the reasons in it. For "
        "inspecting a rejected run, not for committing.",
    )
    parser.add_argument("--verbose", action="store_true", help="Log at debug level.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s %(message)s",
        stream=sys.stderr,
    )

    try:
        index_payload = load_json(args.index_row, what="the index row")
        # The publisher prints {"bucket", "key", "row"}; the index table returns
        # the row itself. Both are in use, so both are accepted here.
        if isinstance(index_payload, dict) and "row" in index_payload:
            index_payload = index_payload["row"]
        if not isinstance(index_payload, dict):
            raise CaptureError("the index row must be a JSON object.")

        contract = load_json(args.contract, what="the result contract")
        if isinstance(contract, dict) and "Parameter" in contract:
            # Output of a parameter read, where the document is a JSON string
            # inside the Value field.
            contract = json.loads(contract["Parameter"]["Value"])
        if not isinstance(contract, dict):
            raise CaptureError("the result contract must be a JSON object.")

        document = build_document(
            index_row=index_payload,
            summary_rows=as_rows(load_json(args.summary, what="the summary"), what="the summary"),
            percentile_rows=as_rows(
                load_json(args.percentiles, what="the percentiles"), what="the percentiles"
            ),
            contract=contract,
            role=args.role,
        )
    except (CaptureError, KeyError, TypeError, ValueError) as error:
        LOG.error("%s", error)
        return 2

    if args.role == "baseline":
        reasons = admit_as_baseline(document)
        if reasons:
            for reason in reasons:
                LOG.error("not fit as a baseline: %s", reason)
            if not args.allow_unfit_baseline:
                LOG.error(
                    "refusing to write a baseline from this run. Measure again under conditions "
                    "that hold, or pass --allow-unfit-baseline to inspect the document."
                )
                return 1
            document["admission_failures"] = reasons
            LOG.warning("writing an unfit baseline with %d recorded objection(s).", len(reasons))

    rendered = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if args.out:
        try:
            with open(args.out, "w", encoding="utf-8") as handle:
                handle.write(rendered)
        except OSError as error:
            LOG.error("cannot write %s: %s", args.out, error)
            return 2
        LOG.info(
            "wrote %s: %d phase(s), ladder %s",
            args.out,
            len(document["phases"]),
            document["conditions"]["ladder_fingerprint"],
        )
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
