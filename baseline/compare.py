#!/usr/bin/env python3
"""Judge a candidate run against a baseline, and say when it cannot.

The arithmetic a regression gate is usually written with does not survive this
pipeline. A percentile here is read off a merged bucket ladder, so it is known
only to the width of the bucket it falls in; subtracting one bucketed
percentile from another produces a difference whose own error is the sum of two
bucket widths, and comparing that difference against an allowance narrower than
those widths produces a verdict with no support in the data. The verdict is
not wrong half the time, which would be noticed. It is confident, stable,
reproducible and unfounded, which is not.

So this tool does interval arithmetic and returns THREE outcomes per gate:

  pass        the candidate's whole interval sits at or below the allowed
              ceiling, so the figure is at or below it whatever its position
              inside the bucket.
  regressed   the candidate's whole interval sits above the ceiling.
  unresolved  the interval straddles the ceiling. Nothing follows from the
              data: the true figure may be either side of it.

`unresolved` is the outcome that makes the other two mean something, and it is
not a hedge. It has a specific remedy, which the report prints: add a ladder
boundary at the ceiling the gate is testing against. The ladder exists exactly
so a percentile can be merged across workers at all, and a boundary placed at
the figure a release is judged against is the one place where a bucket's width
otherwise decides the verdict. Refreshing the ladder invalidates the baselines
captured under the old one - the fingerprint check below will say so - and that
is the honest price of resolving the gate rather than guessing it.

The exact figures are treated exactly. Request counts, error rates, achieved
rate and dropped iterations all combine across the fleet without loss, so they
get two-valued verdicts. The three-valued logic is a consequence of bucketing
and nothing else, and applying it where it is not needed would hide the
distinction.

Before any gate runs, the preconditions decide whether a comparison is valid at
all. A run at a different offered rate, under a different ladder, or on a fleet
that came up short is not a worse or better run - it is a measurement of
something else, and the comparison is VOID rather than failed. A void
comparison and a failed one need different responses from whoever reads the
report, so they get different exit codes.

    compare.py --baseline baseline/profiles/http-read.json \\
      --candidate build/candidate.json --thresholds baseline/thresholds.yaml
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from typing import Any

LOG = logging.getLogger("compare")

SUPPORTED_SCHEMA = 1

PASS = "pass"
REGRESSED = "regressed"
UNRESOLVED = "unresolved"
UNMATCHED = "unmatched"
SKIPPED = "not_applicable"

# Exit codes. A void comparison is separated from a failed one because the two
# ask for different things: a failure asks for the change to be looked at, a
# void asks for the run to be done again properly. Collapsing them trains
# whoever reads the pipeline to retry on both.
EXIT_PASS = 0
EXIT_REGRESSED = 1
EXIT_NOT_JUDGED = 2
EXIT_VOID = 3
EXIT_USAGE = 4


class CompareError(RuntimeError):
    """Raised when the inputs cannot support a comparison of any kind."""


def load_document(path: str, *, what: str) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except OSError as error:
        raise CompareError(f"cannot read the {what} at {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise CompareError(f"the {what} at {path} is not JSON: {error}") from error
    if not isinstance(document, dict):
        raise CompareError(f"the {what} must be a JSON object.")
    if document.get("schema_version") != SUPPORTED_SCHEMA:
        raise CompareError(
            f"the {what} is schema version {document.get('schema_version')!r}; this tool reads "
            f"version {SUPPORTED_SCHEMA}. The figures may well be readable, but a document whose "
            "shape is not the one this tool was written against can differ in which field means "
            "what, and a silent misreading of a threshold is the failure being avoided here."
        )
    if "phases" not in document or "conditions" not in document:
        raise CompareError(f"the {what} has no phases or no conditions; it is not a measurement.")
    return document


def load_thresholds(path: str) -> dict[str, Any]:
    """Read the policy. YAML by preference, JSON accepted.

    JSON is accepted because the YAML parser is a third-party package and this
    tool runs in a pipeline; a gate that cannot run because a dependency is
    missing fails open in every pipeline that treats a crash as
    infrastructure flake, so there is a path that needs nothing installed.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise CompareError(f"cannot read the policy at {path}: {error}") from error

    if path.endswith(".json"):
        try:
            policy = json.loads(text)
        except json.JSONDecodeError as error:
            raise CompareError(f"the policy at {path} is not JSON: {error}") from error
    else:
        try:
            import yaml
        except ImportError as error:
            raise CompareError(
                f"reading {path} needs a YAML parser, which is not installed. Install one, or "
                "convert the policy to JSON and pass that - the two are read identically here."
            ) from error
        try:
            policy = yaml.safe_load(text)
        except yaml.YAMLError as error:
            raise CompareError(f"the policy at {path} is not valid YAML: {error}") from error

    if not isinstance(policy, dict):
        raise CompareError("the policy must be a mapping.")
    if policy.get("schema_version") != SUPPORTED_SCHEMA:
        raise CompareError(
            f"the policy is schema version {policy.get('schema_version')!r}; this tool reads "
            f"{SUPPORTED_SCHEMA}."
        )
    if not isinstance(policy.get("gates"), list) or not policy["gates"]:
        raise CompareError(
            "the policy declares no gates. An empty policy passes every candidate, which is "
            "indistinguishable in a pipeline from a policy that was checked and satisfied."
        )
    return policy


def scenario_id(value: Any) -> str:
    """The scenario's identity, however it was spelled.

    The launcher is given a path and the policy is written with a name, so one
    side carries a `.js` suffix and a directory and the other does not. Both
    name the same program, and a selector that failed to match on the spelling
    would report as unmatched - which this project treats as a failure, so the
    difference would surface as a broken gate rather than as a mismatch.
    """
    text = str(value or "")
    text = text.rsplit("/", 1)[-1]
    if text.endswith(".js"):
        text = text[: -len(".js")]
    return text


def check_preconditions(
    baseline: dict[str, Any], candidate: dict[str, Any], defaults: dict[str, Any]
) -> list[str]:
    """Why these two documents cannot be compared at all.

    Each reason here voids the comparison. None of them is a statement about
    the change under test: they all say that the candidate measured a different
    thing, and the only honest verdict on a different thing is no verdict.
    """
    reasons: list[str] = []
    base_conditions = baseline["conditions"]
    cand_conditions = candidate["conditions"]

    if defaults.get("require_comparable", True) and not cand_conditions.get(
        "comparable_to_baseline"
    ):
        reasons.append(
            f"the candidate is marked not comparable: {cand_conditions.get('shortfall')} "
            f"worker(s) short, {cand_conditions.get('interruptible_workers')} on reclaimable "
            "capacity. A worker reclaimed mid-run withdraws its share of the offered load, which "
            "is indistinguishable in the target's metrics from the target degrading."
        )
    if defaults.get("require_comparable", True) and not base_conditions.get(
        "comparable_to_baseline"
    ):
        reasons.append(
            "the baseline itself is marked not comparable, so every verdict taken against it "
            "would quote a figure measured under conditions that did not hold."
        )

    if defaults.get("require_same_ladder", True):
        base_ladder = base_conditions.get("ladder_fingerprint")
        cand_ladder = cand_conditions.get("ladder_fingerprint")
        if base_ladder != cand_ladder:
            differences = describe_ladder_change(
                base_conditions.get("ladder_boundaries_ms") or [],
                cand_conditions.get("ladder_boundaries_ms") or [],
            )
            reasons.append(
                f"the ladders differ: baseline {base_ladder}, candidate {cand_ladder}. "
                f"{differences} A percentile is located by a cumulative sum over shared "
                "boundaries, so two runs aggregated over different ladders have no percentile in "
                "common to compare. Recapture the baseline under the current ladder."
            )

    if defaults.get("require_same_scenario", True):
        base_scenario = scenario_id(baseline["run"].get("scenario"))
        cand_scenario = scenario_id(candidate["run"].get("scenario"))
        if base_scenario != cand_scenario:
            reasons.append(
                f"the baseline ran {base_scenario or '(unnamed)'} and the candidate ran "
                f"{cand_scenario or '(unnamed)'}. These are different programs offering "
                "different work."
            )

    tolerance = float(defaults.get("offered_rate_tolerance_pct", 2.0))
    base_rate = base_conditions.get("effective_offered_rate")
    cand_rate = cand_conditions.get("effective_offered_rate")
    if base_rate is None or cand_rate is None:
        reasons.append(
            "one of the documents does not record its effective offered rate, so the comparison "
            "cannot establish that the two runs offered the same work."
        )
    else:
        base_rate = float(base_rate)
        cand_rate = float(cand_rate)
        if base_rate <= 0:
            reasons.append(f"the baseline's offered rate is {base_rate}, which bounds nothing.")
        else:
            drift = abs(cand_rate - base_rate) / base_rate * 100.0
            if drift > tolerance:
                reasons.append(
                    f"the offered rates differ by {drift:.2f}%, past the {tolerance:.2f}% "
                    f"tolerance: baseline {base_rate:.1f}/s against candidate {cand_rate:.1f}/s. "
                    "Latency is a function of offered load, so this is a comparison between two "
                    "load levels rather than between two revisions."
                )
    return reasons


def describe_ladder_change(baseline: list[Any], candidate: list[Any]) -> str:
    """Which boundaries moved, in a line.

    Printing two forty-element lists and leaving the reader to diff them is
    what makes a fingerprint mismatch get overridden rather than fixed.
    """
    base_set = {float(b) for b in baseline}
    cand_set = {float(b) for b in candidate}
    added = sorted(cand_set - base_set)
    removed = sorted(base_set - cand_set)
    if not added and not removed:
        return "The boundary sets are equal, so the difference is in their order or their repeats."
    parts = []
    if added:
        parts.append(f"added {', '.join(f'{b:g}' for b in added[:6])}")
    if removed:
        parts.append(f"removed {', '.join(f'{b:g}' for b in removed[:6])}")
    return "The candidate's ladder " + " and ".join(parts) + "."


def allowance(rule: dict[str, Any], baseline_value: float, *, absolute_key: str) -> float:
    """How much worse the candidate may be before it has regressed.

    An absolute and a relative allowance both appear because neither works
    across the range on its own: ten percent of a three-millisecond baseline is
    a third of a millisecond, finer than any boundary on the ladder, and a flat
    fifty milliseconds against a two-second baseline is noise. Given both, the
    WIDER one is used by default, so each acts as a floor under the other -
    the alternative is a gate that is accidentally unresolvable at one end of
    the range.
    """
    # Checked before anything is combined, so the vocabulary is validated
    # wherever it is written. A rule with no allowance permits nothing whatever
    # `combine` says, but a policy carrying a misspelled key is a policy that
    # was not read the way it was written, and the next edit to that rule would
    # inherit the typo silently.
    combine = str(rule.get("combine", "wider"))
    if combine not in ("wider", "narrower"):
        raise CompareError(f"combine must be 'wider' or 'narrower'; got {combine!r}.")

    absolute = rule.get(absolute_key)
    relative = rule.get("allow_rel_pct")
    candidates: list[float] = []
    if absolute is not None:
        candidates.append(float(absolute))
    if relative is not None:
        candidates.append(abs(baseline_value) * float(relative) / 100.0)
    if not candidates:
        return 0.0
    return max(candidates) if combine == "wider" else min(candidates)


def judge_interval(
    *, candidate: dict[str, Any], baseline: dict[str, Any], allowed: float
) -> dict[str, Any]:
    """Three-valued verdict on one bucketed percentile.

    The ceiling is computed from the baseline's UPPER boundary, which is the
    baseline read at its slowest plausible value. That is the generous reading
    and it is chosen deliberately: it can never call a regression that is not
    one, at the cost of missing an increase smaller than the baseline's own
    bucket. A gate that cried wolf would be switched off within a month, and a
    gate that is switched off has a resolution of infinity.

    The cost is therefore stated rather than hidden. `resolution_floor_ms` is
    the smallest increase this gate is guaranteed to catch: the allowance plus
    both intervals' widths. An increase below it may be real and may still
    report as a pass, and no allowance narrower than it can change that.
    """
    ceiling = baseline["at_or_below_ms"] + allowed
    cand_low = candidate["above_ms"]
    cand_high = candidate["at_or_below_ms"]

    if cand_high <= ceiling:
        verdict = PASS
    elif cand_low >= ceiling:
        verdict = REGRESSED
    else:
        verdict = UNRESOLVED

    result = {
        "verdict": verdict,
        "baseline_interval_ms": [baseline["above_ms"], baseline["at_or_below_ms"]],
        "candidate_interval_ms": [cand_low, cand_high],
        "allowance_ms": allowed,
        "ceiling_ms": ceiling,
        "resolution_floor_ms": allowed
        + baseline["interval_width_ms"]
        + candidate["interval_width_ms"],
    }
    if verdict == UNRESOLVED:
        result["remedy"] = (
            f"the candidate's bucket spans {cand_low:g} to {cand_high:g}ms and the ceiling is "
            f"{ceiling:g}ms, so the figure may be either side of it. Add a boundary at "
            f"{ceiling:g} to latency_bucket_boundaries_ms and recapture the baseline - the "
            "ladder change invalidates the current one."
        )
    if candidate.get("unbounded_above"):
        result["note"] = (
            f"the candidate's figure is in the ladder's final bucket, above {cand_low:g}ms with "
            "no upper bound. No interval can place it below any ceiling, so this gate can only "
            "ever report a regression or stay unresolved until the ladder is extended."
        )
    return result


def judge_scalar(
    *, candidate: float | None, baseline: float | None, rule: dict[str, Any], label: str
) -> dict[str, Any]:
    """Two-valued verdict on a figure that combines exactly across the fleet.

    No interval arithmetic, because there is no interval: counts add and sums
    add, so an error rate and an achieved rate are exact over the whole fleet.
    Treating them as uncertain would import a caveat that belongs to the
    percentiles alone.
    """
    hard_limit = rule.get("max_abs")
    if hard_limit is not None:
        if candidate is None:
            return {
                "verdict": UNRESOLVED,
                "detail": f"{label} was not measured, so the limit of {hard_limit} is unchecked.",
            }
        exceeded = float(candidate) > float(hard_limit)
        return {
            "verdict": REGRESSED if exceeded else PASS,
            "candidate": candidate,
            "limit": float(hard_limit),
            "detail": (
                f"{label} is {candidate:g} against a hard limit of {float(hard_limit):g}"
                if exceeded
                else f"{label} is {candidate:g}, within the limit of {float(hard_limit):g}"
            ),
        }

    if baseline is None or candidate is None:
        return {
            "verdict": UNRESOLVED,
            "detail": (
                f"{label} is absent from the "
                f"{'baseline' if baseline is None else 'candidate'}, so there is nothing to "
                "compare. A missing figure reads like a zero to anything that defaults it, and a "
                "zero error rate is a pass."
            ),
        }

    direction = str(rule.get("direction", "not_above"))
    if direction not in ("not_above", "not_below"):
        raise CompareError(f"direction must be 'not_above' or 'not_below'; got {direction!r}.")
    allowed = allowance(rule, float(baseline), absolute_key="allow_abs")

    if direction == "not_above":
        bound = float(baseline) + allowed
        regressed = float(candidate) > bound
        shape = "at or below"
    else:
        bound = float(baseline) - allowed
        regressed = float(candidate) < bound
        shape = "at or above"

    return {
        "verdict": REGRESSED if regressed else PASS,
        "baseline": float(baseline),
        "candidate": float(candidate),
        "allowance": allowed,
        "bound": bound,
        "detail": (
            f"{label} moved from {float(baseline):g} to {float(candidate):g}; the gate requires "
            f"{shape} {bound:g}"
        ),
    }


def series_for(entry: dict[str, Any], selector: dict[str, Any]) -> tuple[str | None, str | None]:
    """Pick the latency series a gate is scoped to.

    A named series is looked up directly. With no name given, a phase carrying
    exactly one series uses it and a phase carrying several is an error rather
    than a choice: picking one of them would make the gate's subject depend on
    the order the query returned its rows.
    """
    latency = entry.get("latency") or {}
    wanted = selector.get("series")
    if wanted is not None:
        if str(wanted) in latency:
            return str(wanted), None
        return None, (
            f"no latency series named {wanted!r}; the phase carries "
            f"{', '.join(repr(k) for k in sorted(latency)) or 'none'}."
        )
    if len(latency) == 1:
        return next(iter(latency)), None
    if not latency:
        return None, "the phase carries no latency series at all."
    return None, (
        f"the phase carries {len(latency)} latency series "
        f"({', '.join(repr(k) for k in sorted(latency))}) and the gate names none, so its "
        "subject would depend on row order. Add `series:` to the selector."
    )


def evaluate_gate(
    gate: dict[str, Any],
    *,
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    defaults: dict[str, Any],
) -> dict[str, Any]:
    gate_id = str(gate.get("id") or "(unnamed)")
    selector = gate.get("select") or {}
    result: dict[str, Any] = {"id": gate_id, "select": selector, "checks": {}}

    # A gate for another scenario is not applicable, not unmatched. The policy
    # holds gates for every scenario the platform runs and one run exercises
    # one of them, so treating the rest as unmatched would fail every
    # comparison on gates that were never meant to apply to it.
    wanted_scenario = selector.get("scenario")
    if wanted_scenario is not None and scenario_id(wanted_scenario) != scenario_id(
        candidate["run"].get("scenario")
    ):
        result["verdict"] = SKIPPED
        result["detail"] = (
            f"scoped to {scenario_id(wanted_scenario)}; this run was "
            f"{scenario_id(candidate['run'].get('scenario')) or '(unnamed)'}."
        )
        return result

    phase = selector.get("phase")
    if phase is None:
        result["verdict"] = UNMATCHED
        result["detail"] = "the selector names no phase, so it does not identify any figures."
        return result
    phase = str(phase)

    for which, document in (("baseline", baseline), ("candidate", candidate)):
        if phase not in document["phases"]:
            result["verdict"] = UNMATCHED
            result["detail"] = (
                f"phase {phase!r} is not in the {which}, which carries "
                f"{', '.join(repr(p) for p in sorted(document['phases'])) or 'no phases'}. A "
                "renamed phase would otherwise switch this gate off and report a pass."
            )
            return result

    base_entry = baseline["phases"][phase]
    cand_entry = candidate["phases"][phase]

    min_windows = int(defaults.get("min_windows", 0))
    windows = cand_entry.get("windows")
    if windows is not None and windows < min_windows:
        result["verdict"] = UNRESOLVED
        result["detail"] = (
            f"the candidate's phase {phase!r} was computed from {windows} aggregation window(s), "
            f"below the {min_windows} the policy requires. The figures exist; the averaging their "
            "decimal places imply does not."
        )
        return result

    rules = gate.get("rules") or {}
    if not rules:
        result["verdict"] = UNMATCHED
        result["detail"] = "the gate declares no rules, so it checks nothing and would pass."
        return result

    percentile_rules = rules.get("percentile") or {}
    if percentile_rules:
        min_observations = int(defaults.get("min_latency_observations", 0))
        observations = cand_entry.get("latency_observations")
        if observations is not None and observations < min_observations:
            result["checks"]["percentile"] = {
                "verdict": UNRESOLVED,
                "detail": (
                    f"{int(observations)} latency observation(s), below the {min_observations} "
                    "floor. A tail percentile over a few hundred samples moves by a bucket "
                    "between identical runs."
                ),
            }
        else:
            base_series, base_problem = series_for(base_entry, selector)
            cand_series, cand_problem = series_for(cand_entry, selector)
            if base_problem or cand_problem:
                result["checks"]["percentile"] = {
                    "verdict": UNMATCHED,
                    "detail": f"baseline: {base_problem or 'ok'}; candidate: "
                    f"{cand_problem or 'ok'}",
                }
            else:
                for label, rule in sorted(percentile_rules.items()):
                    base_value = base_entry["latency"][base_series].get(label)
                    cand_value = cand_entry["latency"][cand_series].get(label)
                    if base_value is None or cand_value is None:
                        result["checks"][label] = {
                            "verdict": UNMATCHED,
                            "detail": f"{label} is absent from the "
                            f"{'baseline' if base_value is None else 'candidate'}.",
                        }
                        continue
                    if base_value.get("unbounded_above"):
                        result["checks"][label] = {
                            "verdict": UNRESOLVED,
                            "detail": (
                                f"the baseline's {label} is in the ladder's final bucket, above "
                                f"{base_value['above_ms']:g}ms with no upper bound, so no ceiling "
                                "can be computed from it. Extend the ladder and recapture."
                            ),
                        }
                        continue
                    allowed = allowance(
                        rule, base_value["at_or_below_ms"], absolute_key="allow_abs_ms"
                    )
                    result["checks"][label] = judge_interval(
                        candidate=cand_value, baseline=base_value, allowed=allowed
                    )

    for field in ("error_rate_pct", "achieved_rate_per_s", "dropped_iterations", "mean_ms"):
        rule = rules.get(field)
        if not rule:
            continue
        result["checks"][field] = judge_scalar(
            candidate=cand_entry.get(field),
            baseline=base_entry.get(field),
            rule=rule,
            label=field,
        )

    verdicts = {check["verdict"] for check in result["checks"].values()}
    if not verdicts:
        result["verdict"] = UNMATCHED
        result["detail"] = "no rule in this gate matched a figure in either document."
    elif REGRESSED in verdicts:
        result["verdict"] = REGRESSED
    elif UNMATCHED in verdicts:
        result["verdict"] = UNMATCHED
    elif UNRESOLVED in verdicts:
        result["verdict"] = UNRESOLVED
    else:
        result["verdict"] = PASS
    return result


def compare(
    *, baseline: dict[str, Any], candidate: dict[str, Any], policy: dict[str, Any]
) -> dict[str, Any]:
    defaults = policy.get("defaults") or {}
    report: dict[str, Any] = {
        "baseline_run": baseline["run"].get("run_id"),
        "candidate_run": candidate["run"].get("run_id"),
        "scenario": scenario_id(candidate["run"].get("scenario")),
        "offered_rate_per_s": candidate["conditions"].get("effective_offered_rate"),
        "ladder_fingerprint": candidate["conditions"].get("ladder_fingerprint"),
        "void_reasons": check_preconditions(baseline, candidate, defaults),
        "gates": [],
    }
    if report["void_reasons"]:
        report["outcome"] = "void"
        return report

    report["gates"] = [
        evaluate_gate(gate, baseline=baseline, candidate=candidate, defaults=defaults)
        for gate in policy["gates"]
    ]

    applicable = [gate for gate in report["gates"] if gate["verdict"] != SKIPPED]
    if not applicable:
        report["outcome"] = "unmatched"
        report["detail"] = (
            "no gate in the policy applies to this scenario. A comparison that checked nothing "
            "is reported as such rather than as a pass."
        )
        return report

    verdicts = {gate["verdict"] for gate in applicable}
    if REGRESSED in verdicts:
        report["outcome"] = "regressed"
    elif UNMATCHED in verdicts:
        report["outcome"] = "unmatched"
    elif UNRESOLVED in verdicts:
        report["outcome"] = "unresolved"
    else:
        report["outcome"] = "pass"
    return report


def render_text(report: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append(f"candidate {report['candidate_run']} against baseline {report['baseline_run']}")
    lines.append(
        f"  scenario {report['scenario'] or '(unnamed)'} at "
        f"{report['offered_rate_per_s']}/s offered, ladder {report['ladder_fingerprint']}"
    )
    lines.append("")

    if report["void_reasons"]:
        lines.append("VOID - the two runs do not measure the same thing:")
        for reason in report["void_reasons"]:
            lines.append(f"  - {reason}")
        lines.append("")
        lines.append("No verdict was taken. This is not a failure of the change under test.")
        return "\n".join(lines) + "\n"

    for gate in report["gates"]:
        if gate["verdict"] == SKIPPED:
            lines.append(f"  skip  {gate['id']}: {gate.get('detail', '')}")
            continue
        lines.append(f"{gate['verdict'].upper():>10}  {gate['id']}")
        if gate.get("detail"):
            lines.append(f"            {gate['detail']}")
        for name, check in sorted(gate["checks"].items()):
            lines.append(f"            {check['verdict']:>10}  {name}")
            if "candidate_interval_ms" in check:
                lines.append(
                    f"                        baseline "
                    f"{check['baseline_interval_ms'][0]:g}-"
                    f"{check['baseline_interval_ms'][1]:g}ms, candidate "
                    f"{check['candidate_interval_ms'][0]:g}-"
                    f"{check['candidate_interval_ms'][1]:g}ms, ceiling "
                    f"{check['ceiling_ms']:g}ms"
                )
                lines.append(
                    f"                        smallest increase this gate can catch: "
                    f"{check['resolution_floor_ms']:g}ms"
                )
            for key in ("detail", "remedy", "note"):
                if check.get(key):
                    lines.append(f"                        {key}: {check[key]}")
        lines.append("")

    lines.append(f"outcome: {report['outcome'].upper()}")
    if report.get("detail"):
        lines.append(report["detail"])
    return "\n".join(lines) + "\n"


def exit_code(report: dict[str, Any], defaults: dict[str, Any]) -> int:
    outcome = report["outcome"]
    if outcome == "void":
        return EXIT_VOID
    if outcome == "regressed":
        return EXIT_REGRESSED
    if outcome == "unresolved":
        return EXIT_NOT_JUDGED if defaults.get("on_unresolved", "fail") == "fail" else EXIT_PASS
    if outcome == "unmatched":
        return (
            EXIT_NOT_JUDGED
            if defaults.get("on_unmatched_selector", "fail") == "fail"
            else EXIT_PASS
        )
    return EXIT_PASS


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog="Exit codes: 0 pass, 1 regressed, 2 not judged (unresolved or unmatched), "
        "3 void (the runs are not comparable), 4 bad input.",
    )
    parser.add_argument("--baseline", required=True, help="The blessed measurement document.")
    parser.add_argument("--candidate", required=True, help="The measurement document to judge.")
    parser.add_argument("--thresholds", required=True, help="The regression policy, YAML or JSON.")
    parser.add_argument(
        "--format", choices=("text", "json"), default="text", help="Report format."
    )
    parser.add_argument("--out", help="Write the report here as well as to standard output.")
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
        baseline = load_document(args.baseline, what="baseline")
        candidate = load_document(args.candidate, what="candidate")
        policy = load_thresholds(args.thresholds)
        report = compare(baseline=baseline, candidate=candidate, policy=policy)
    except CompareError as error:
        LOG.error("%s", error)
        return EXIT_USAGE

    rendered = (
        json.dumps(report, indent=2, sort_keys=True) + "\n"
        if args.format == "json"
        else render_text(report)
    )
    sys.stdout.write(rendered)
    if args.out:
        try:
            with open(args.out, "w", encoding="utf-8") as handle:
                handle.write(rendered)
        except OSError as error:
            LOG.error("cannot write %s: %s", args.out, error)
            return EXIT_USAGE

    return exit_code(report, policy.get("defaults") or {})


if __name__ == "__main__":
    sys.exit(main())
