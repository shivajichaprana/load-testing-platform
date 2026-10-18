"""Fixtures for the baseline and comparison suites.

Two decisions are worth stating.

The tools under test are scripts rather than an installed package, so they are
loaded from their path. Importing them any other way would need a packaging
layout the fleet does not use, and a test that needs the code rearranged to be
testable is testing a rearrangement.

The measurement documents are built by `capture.build_document` rather than
written out as literals. A literal fixture drifts from the shape the tool
actually produces, and the drift is silent: the comparison would be exercised
against a document no run can emit, which is the one thing these fixtures must
not be.
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]


def load_tool(name: str) -> ModuleType:
    """Load one of the baseline tools from its path in this checkout."""
    path = REPO_ROOT / "baseline" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"_tool_{name}", path)
    if spec is None or spec.loader is None:  # pragma: no cover - a broken checkout
        raise AssertionError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


capture = load_tool("capture")
compare = load_tool("compare")


def ladder_from_variables() -> list[float]:
    """The shared latency ladder, read out of the Terraform default.

    Read from the configuration rather than copied into the suite. The ladder
    is the one value the figures, the policy's allowances and the comparison's
    resolution all depend on, so a suite carrying its own copy would keep
    passing after the real ladder moved - and a moved ladder invalidates every
    committed baseline.
    """
    text = (REPO_ROOT / "variables.tf").read_text(encoding="utf-8")
    match = re.search(
        r'variable\s+"latency_bucket_boundaries_ms"\s*\{.*?default\s*=\s*\[(.*?)\]',
        text,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError("latency_bucket_boundaries_ms has no readable default")
    return [float(part) for part in re.findall(r"[0-9]+(?:\.[0-9]+)?", match.group(1))]


LADDER = ladder_from_variables()


def bucket_for(value: float) -> tuple[float, float]:
    """The ladder interval a figure falls in, as the query would report it.

    A percentile is located by a cumulative sum over the boundaries, so it is
    known only to the width of its bucket. Returning the pair is what lets a
    test state a figure in milliseconds and still exercise the interval
    arithmetic the real documents carry.
    """
    previous = 0.0
    for boundary in LADDER:
        if value <= boundary:
            return previous, boundary
        previous = boundary
    return previous, previous


def contract(**overrides: Any) -> dict[str, Any]:
    """The result contract a run was aggregated under."""
    document = {
        "schema_version": 1,
        "latency_ceiling_ms": 250,
        "latency_buckets_ms": list(LADDER),
    }
    document.update(overrides)
    return document


def index_row(**overrides: Any) -> dict[str, Any]:
    """A launcher index row for a fully placed, comparable fleet."""
    row = {
        "run_id": "r-2f9c41",
        "start_epoch": 1760000000,
        "scenario": "scenarios/http-read.js",
        "cluster": "load-generators",
        "task_definition": "load-runner:7",
        "load_model": "open",
        "requested_workers": 8,
        "placed_workers": 8,
        "shortfall": 0,
        "interruptible_workers": 0,
        "target_rate": 800,
        "rate_per_worker": 100,
        "effective_offered_rate": 800.0,
        "comparable_to_baseline": True,
    }
    row.update(overrides)
    return row


def summary_row(phase: str = "steady", **overrides: Any) -> dict[str, Any]:
    """A run-summary row healthy enough to be blessed as a baseline."""
    row = {
        "phase": phase,
        "workers": 8,
        "windows": 10,
        "requests": 480000,
        "failed": 0,
        "error_rate_pct": 0.0,
        "dropped_iterations": 0,
        "observed_seconds": 600,
        "achieved_rate_per_s": 800.0,
        "latency_observations": 480000,
        "mean_ms": 120.0,
        "fastest_ms": 8.0,
        "slowest_ms": 900.0,
    }
    row.update(overrides)
    return row


def percentile_row(
    phase: str = "steady",
    label: str = "p95",
    at_or_below_ms: float = 250.0,
    *,
    name: str = "read listing",
    observations: int = 480000,
    above_ms: float | None = None,
) -> dict[str, Any]:
    """A percentile row bracketed the way the merge reports it."""
    if above_ms is None:
        above_ms = bucket_for(at_or_below_ms)[0]
    return {
        "phase": phase,
        "percentile": label,
        "name": name,
        "above_ms": above_ms,
        "at_or_below_ms": at_or_below_ms,
        "observations": observations,
    }


def measurement(
    *,
    role: str = "baseline",
    index_overrides: dict[str, Any] | None = None,
    summary_overrides: dict[str, Any] | None = None,
    percentiles: dict[str, float] | None = None,
    phase: str = "steady",
    series: str = "read listing",
    contract_overrides: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """One measurement document, as `capture.py` would write it.

    `percentiles` maps a label to the figure's upper boundary; the lower one is
    derived from the ladder so that the interval is the one the query would
    have produced rather than a width invented by the test.
    """
    figures = {"p50": 50.0, "p95": 250.0, "p99": 500.0} if percentiles is None else percentiles
    return capture.build_document(
        index_row=index_row(**(index_overrides or {})),
        summary_rows=[summary_row(phase, **(summary_overrides or {}))],
        percentile_rows=[
            percentile_row(phase, label, value, name=series, observations=480000)
            for label, value in figures.items()
        ],
        contract=contract(**(contract_overrides or {})),
        role=role,
    )


def policy(**overrides: Any) -> dict[str, Any]:
    """A one-gate policy over the read path's steady phase."""
    document = {
        "schema_version": 1,
        "defaults": {
            "require_comparable": True,
            "require_same_ladder": True,
            "require_same_scenario": True,
            "offered_rate_tolerance_pct": 2.0,
            "min_latency_observations": 1000,
            "min_windows": 3,
            "on_unresolved": "fail",
            "on_unmatched_selector": "fail",
        },
        "gates": [
            {
                "id": "read-steady",
                "select": {"scenario": "http-read", "phase": "steady"},
                "rules": {
                    "percentile": {"p95": {"allow_abs_ms": 50, "allow_rel_pct": 15}},
                    "error_rate_pct": {"allow_abs": 0.1},
                    "achieved_rate_per_s": {"direction": "not_below", "allow_rel_pct": 3},
                    "dropped_iterations": {"max_abs": 0},
                },
            }
        ],
    }
    document.update(overrides)
    return document


def committed_policy() -> dict[str, Any]:
    """The policy this repository actually ships, read through the tool."""
    return compare.load_thresholds(str(REPO_ROOT / "baseline" / "thresholds.yaml"))


def write_json(path: Path, document: Any) -> str:
    path.write_text(json.dumps(document), encoding="utf-8")
    return str(path)
