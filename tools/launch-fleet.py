#!/usr/bin/env python3
"""Launch a load-generator fleet and reconcile what was actually placed.

A fleet is launched, not scheduled. Nothing maintains a desired count, so the
launcher owns three things the platform will not do for it:

  * Batching. A launch request places a bounded number of tasks, so a larger
    fleet is several requests.

  * Reconciliation. A successful response can report placement failures
    alongside the tasks it did place, so the number of workers that exist is
    never assumed from the number requested.

  * The synchronized start. Workers do not begin generating load when their
    container starts; they wait for one wall-clock instant supplied at launch.
    Task start time is tens of seconds and varies between workers by more than
    the ramp being measured, so a fleet that starts on container start smears
    the ramp across its own scheduling noise and reports it as the profile.

By default nothing is sent: the plan is printed and the process exits. Passing
--execute is the only way to place tasks.

Exit status is 0 only when the fleet that exists is the fleet that was asked
for, or when a shortfall was explicitly accepted.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import logging
import math
import sys
import time
import uuid
from typing import Any, Iterable, Sequence

LOG = logging.getLogger("launch-fleet")

# A launch request places at most this many tasks. The figure belongs to the
# service, not to this tool, and the batching exists only because of it.
MAX_TASKS_PER_REQUEST = 10

# Placement failure reasons that are worth retrying because they describe a
# transient shortage rather than a wrong request.
RETRYABLE_FAILURE_FRAGMENTS = (
    "capacity is unavailable",
    "capacityproviderexception",
    "throttl",
)


class FleetError(RuntimeError):
    """A condition that should stop the launch rather than be worked around."""


@dataclasses.dataclass(frozen=True)
class FleetPlan:
    """What is to be launched, with every derived figure kept rather than
    recomputed at the point of use."""

    cluster: str
    task_definition: str
    worker_count: int
    subnets: tuple[str, ...]
    security_groups: tuple[str, ...]
    assign_public_ip: bool
    run_id: str
    start_epoch: int
    target_rate: float
    load_model: str

    @property
    def batches(self) -> tuple[int, ...]:
        """Task counts per launch request."""
        return split_into_batches(self.worker_count, MAX_TASKS_PER_REQUEST)

    @property
    def rate_per_worker(self) -> float:
        """Each worker's uniform share of the offered rate.

        Uniform on purpose. A request places identical tasks, so a per-worker
        index CANNOT be supplied as an override: every task in one request
        receives the same overrides. The share is therefore the same for all of
        them, and a scenario that needs to partition its data by worker must
        read its own identity from the task metadata available inside the
        container rather than expect it here. The launcher assigns indices
        afterwards, for the record, from the order the tasks were placed in.
        """
        if self.worker_count <= 0:
            return 0.0
        return self.target_rate / self.worker_count

    def to_dict(self) -> dict[str, Any]:
        data = dataclasses.asdict(self)
        data["batches"] = list(self.batches)
        data["rate_per_worker"] = round(self.rate_per_worker, 4)
        data["start_iso"] = time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.start_epoch)
        )
        return data


@dataclasses.dataclass
class LaunchOutcome:
    """What the launch produced, as distinct from what it asked for."""

    requested: int
    task_arns: list[str] = dataclasses.field(default_factory=list)
    failures: list[dict[str, str]] = dataclasses.field(default_factory=list)
    capacity_providers: dict[str, str] = dataclasses.field(default_factory=dict)

    @property
    def placed(self) -> int:
        return len(self.task_arns)

    @property
    def shortfall(self) -> int:
        return max(0, self.requested - self.placed)

    @property
    def interruptible(self) -> list[str]:
        return sorted(
            arn
            for arn, provider in self.capacity_providers.items()
            if provider.upper().endswith("SPOT")
        )

    def worker_index(self) -> dict[str, int]:
        """Index assigned to each placed worker, for the run's record only."""
        return {arn: i for i, arn in enumerate(sorted(self.task_arns))}


def split_into_batches(total: int, per_request: int) -> tuple[int, ...]:
    """Split a worker count into launch requests of at most `per_request`."""
    if total < 0:
        raise FleetError("a fleet cannot have a negative worker count")
    if per_request < 1:
        raise FleetError("a launch request must place at least one task")
    whole, remainder = divmod(total, per_request)
    batches = [per_request] * whole + ([remainder] if remainder else [])
    return tuple(batches)


def start_instant(delay_seconds: int, now: float | None = None) -> int:
    """The wall-clock second every worker waits for.

    Whole seconds, because the value travels as text through an environment
    variable and a fractional instant invites each worker to round it
    differently.
    """
    if delay_seconds < 1:
        raise FleetError("the start delay must be at least one second")
    return int(math.ceil((time.time() if now is None else now) + delay_seconds))


def is_retryable(failure: dict[str, str]) -> bool:
    text = " ".join(str(failure.get(k, "")) for k in ("reason", "detail")).lower()
    return any(fragment in text for fragment in RETRYABLE_FAILURE_FRAGMENTS)


def build_overrides(plan: FleetPlan) -> dict[str, Any]:
    """Per-run values, which deliberately live in the request and not in the
    task definition: two runs of one scenario then differ in their launch and
    not in their definition, which is what lets the definition's revision be
    part of a result's provenance."""
    environment = [
        {"name": "RUNNER_RUN_ID", "value": plan.run_id},
        {"name": "RUNNER_START_EPOCH", "value": str(plan.start_epoch)},
        {"name": "RUNNER_WORKER_COUNT", "value": str(plan.worker_count)},
        {"name": "RUNNER_RATE_SHARE", "value": f"{plan.rate_per_worker:.6f}"},
        {"name": "RUNNER_LOAD_MODEL", "value": plan.load_model},
    ]
    return {
        "containerOverrides": [{"name": "runner", "environment": environment}]
    }


def network_configuration(plan: FleetPlan) -> dict[str, Any]:
    return {
        "awsvpcConfiguration": {
            "subnets": list(plan.subnets),
            "securityGroups": list(plan.security_groups),
            "assignPublicIp": "ENABLED" if plan.assign_public_ip else "DISABLED",
        }
    }


class EcsFleet:
    """The only part of this tool that talks to the service."""

    def __init__(self, client: Any) -> None:
        self._client = client

    def run_batch(self, plan: FleetPlan, count: int, attempt: int) -> dict[str, Any]:
        # A deterministic token per batch and attempt, so that a retry after a
        # response that was sent but never received cannot place the batch
        # twice.
        token = f"{plan.run_id}-{count}-{attempt}"
        return self._client.run_task(
            cluster=plan.cluster,
            taskDefinition=plan.task_definition,
            count=count,
            clientToken=token,
            overrides=build_overrides(plan),
            networkConfiguration=network_configuration(plan),
            propagateTags="TASK_DEFINITION",
            enableExecuteCommand=False,
        )

    def describe_capacity(self, cluster: str, arns: Sequence[str]) -> dict[str, str]:
        """Which capacity each worker landed on.

        Recorded because it decides whether the run's numbers may be compared
        with anything: a reclaimed worker withdraws its share of the offered
        load mid-run, and nothing in the target's own metrics distinguishes that
        from the target degrading.
        """
        providers: dict[str, str] = {}
        for chunk in _chunks(arns, 100):
            described = self._client.describe_tasks(cluster=cluster, tasks=list(chunk))
            for task in described.get("tasks", []):
                providers[task["taskArn"]] = task.get("capacityProviderName", "unknown")
        return providers

    def stop(self, cluster: str, arns: Iterable[str], reason: str) -> None:
        for arn in arns:
            self._client.stop_task(cluster=cluster, task=arn, reason=reason)


def _chunks(items: Sequence[str], size: int) -> Iterable[Sequence[str]]:
    for start in range(0, len(items), size):
        yield items[start: start + size]


def launch(fleet: EcsFleet, plan: FleetPlan, max_attempts: int = 3) -> LaunchOutcome:
    """Place the fleet, retrying only the batches whose failures were transient."""
    outcome = LaunchOutcome(requested=plan.worker_count)
    outstanding = list(plan.batches)

    for attempt in range(1, max_attempts + 1):
        if not outstanding:
            break
        LOG.info(
            "launch attempt %d: %d request(s) for %d task(s)",
            attempt, len(outstanding), sum(outstanding),
        )
        retry: list[int] = []
        for count in outstanding:
            response = fleet.run_batch(plan, count, attempt)
            placed = [task["taskArn"] for task in response.get("tasks", [])]
            failures = [
                {"arn": f.get("arn", ""), "reason": f.get("reason", ""), "detail": f.get("detail", "")}
                for f in response.get("failures", [])
            ]
            outcome.task_arns.extend(placed)
            outcome.failures.extend(failures)

            # The response is successful whether or not it placed everything,
            # so the gap is computed rather than inferred from an exception.
            missing = count - len(placed)
            if missing > 0:
                LOG.warning(
                    "request for %d task(s) placed %d; %d missing, %d failure(s) reported",
                    count, len(placed), missing, len(failures),
                )
                if failures and all(is_retryable(f) for f in failures):
                    retry.extend(split_into_batches(missing, MAX_TASKS_PER_REQUEST))
                else:
                    for failure in failures:
                        LOG.error("placement failure not retried: %s", failure)
        outstanding = retry
        if outstanding and attempt < max_attempts:
            time.sleep(min(2 ** attempt, 15))

    if outcome.task_arns:
        outcome.capacity_providers = fleet.describe_capacity(plan.cluster, outcome.task_arns)
    return outcome


def report(plan: FleetPlan, outcome: LaunchOutcome) -> dict[str, Any]:
    interruptible = outcome.interruptible
    effective_rate = plan.rate_per_worker * outcome.placed
    return {
        "run_id": plan.run_id,
        "requested_workers": outcome.requested,
        "placed_workers": outcome.placed,
        "shortfall": outcome.shortfall,
        "start_epoch": plan.start_epoch,
        "target_rate": plan.target_rate,
        "rate_per_worker": round(plan.rate_per_worker, 4),
        "effective_offered_rate": round(effective_rate, 4),
        "interruptible_workers": len(interruptible),
        "comparable_to_baseline": not interruptible and outcome.shortfall == 0,
        "worker_index": outcome.worker_index(),
        "capacity_providers": outcome.capacity_providers,
        "failures": outcome.failures,
    }


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--task-definition", required=True)
    parser.add_argument("--workers", type=int, required=True,
                        help="worker count, as derived by the configuration")
    parser.add_argument("--subnet", action="append", default=[], required=True,
                        dest="subnets", metavar="SUBNET_ID")
    parser.add_argument("--security-group", action="append", default=[], required=True,
                        dest="security_groups", metavar="SECURITY_GROUP_ID")
    parser.add_argument("--target-rate", type=float, required=True,
                        help="offered requests per second for the whole fleet")
    parser.add_argument("--load-model", choices=("open", "closed"), default="open")
    parser.add_argument("--assign-public-ip", action="store_true")
    parser.add_argument("--start-delay", type=int, default=120,
                        help="seconds until the synchronized start instant")
    parser.add_argument("--run-id", default=None)
    parser.add_argument("--on-shortfall", choices=("abort", "proceed"), default="abort",
                        help="abort stops the workers that were placed and fails; "
                             "proceed keeps them and records the reduced offered rate")
    parser.add_argument("--execute", action="store_true",
                        help="actually place tasks; without it the plan is printed and "
                             "nothing is sent")
    parser.add_argument("--json", action="store_true", help="emit the report as JSON only")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args(argv)


def build_plan(args: argparse.Namespace) -> FleetPlan:
    if args.workers < 1:
        raise FleetError("a fleet needs at least one worker")
    if args.target_rate <= 0 and args.load_model == "open":
        raise FleetError("the open model needs a positive target rate")
    return FleetPlan(
        cluster=args.cluster,
        task_definition=args.task_definition,
        worker_count=args.workers,
        subnets=tuple(args.subnets),
        security_groups=tuple(args.security_groups),
        assign_public_ip=bool(args.assign_public_ip),
        run_id=args.run_id or f"run-{uuid.uuid4().hex[:12]}",
        start_epoch=start_instant(args.start_delay),
        target_rate=float(args.target_rate),
        load_model=args.load_model,
    )


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-8s %(name)s %(message)s",
    )

    try:
        plan = build_plan(args)
    except FleetError as error:
        LOG.error("%s", error)
        return 2

    if not args.execute:
        LOG.info("dry run: nothing will be sent")
        print(json.dumps(plan.to_dict(), indent=2, sort_keys=True))
        return 0

    try:
        import boto3  # imported here so a dry run needs nothing installed
    except ImportError:
        LOG.error("the AWS SDK is required to place tasks; a dry run is not")
        return 2

    fleet = EcsFleet(boto3.client("ecs", region_name=None))
    try:
        outcome = launch(fleet, plan)
    except FleetError as error:
        LOG.error("%s", error)
        return 2

    summary = report(plan, outcome)

    if outcome.shortfall:
        LOG.error(
            "fleet is short by %d worker(s): the run would offer %.1f of %.1f requests "
            "per second while reporting the target",
            outcome.shortfall, summary["effective_offered_rate"], plan.target_rate,
        )
        if args.on_shortfall == "abort":
            # Stopping is only possible because the start instant has not
            # passed. Detect a shortfall after it and the run is already
            # spoiled, which is the same reason the delay exists at all.
            remaining = plan.start_epoch - int(time.time())
            LOG.error(
                "stopping %d placed worker(s); %ds remained before the start instant",
                outcome.placed, remaining,
            )
            fleet.stop(plan.cluster, outcome.task_arns, "fleet short of its derived size")
            summary["stopped"] = True

    if outcome.interruptible:
        LOG.warning(
            "%d worker(s) are on interruptible capacity: a reclaimed worker withdraws "
            "its share of the offered load and the result will read as a regression in "
            "the target. These numbers are not comparable with a baseline.",
            len(outcome.interruptible),
        )

    print(json.dumps(summary, indent=2, sort_keys=True))
    if not args.json:
        LOG.info(
            "placed %d/%d worker(s); start instant in %ds",
            outcome.placed, outcome.requested, plan.start_epoch - int(time.time()),
        )

    if outcome.shortfall and args.on_shortfall == "abort":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
