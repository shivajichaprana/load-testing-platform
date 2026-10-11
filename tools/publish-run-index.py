#!/usr/bin/env python3
"""Publish a launcher report as the run's row in the queryable run index.

The measurement table is partitioned by run identifier so that reading one run
touches one prefix, and that column is an injected projection: a query against
it with no run filter fails rather than returning everything. So the question
"what runs are there" cannot be asked of the measurements at all, and this
tool writes the row that answers it.

It is a separate step from the launch, and deliberately so. The launcher has
no cloud dependency at all - its dry run needs nothing installed - and that
property is worth more than saving a pipe:

    launch-fleet.py --execute ... | publish-run-index.py --execute

What it adds to the report is an envelope and a partition. The partition date
comes from the run's START instant and not from the moment of writing, because
the row has to be findable under the date the run belongs to; a run launched
just before midnight UTC writes its measurements under two dates while its
index row stays under the first.

Where the row goes is not written here either. The bucket and the key template
are read from the same result contract the workers read, so the layout exists
in one place and this tool cannot disagree with the catalogue about it.

Unlike a measurement object, this key is intended to be rewritable: it names
the run and nothing else, so republishing a corrected report for the same run
replaces the row rather than adding a second one. A measurement key carries the
worker and the flush sequence for exactly the opposite reason.

By default nothing is written: the row is printed and the process exits.
Passing --execute is the only way to put an object in the bucket.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from typing import Any

LOG = logging.getLogger("publish-run-index")

SCHEMA_VERSION = 1

# Fields the report must carry. Every one of them is a figure a later
# comparison depends on, and a row missing one is worse than no row: a null in
# comparable_to_baseline reads, to anything that filters on it, exactly like a
# run nobody has judged yet.
REQUIRED_FIELDS = (
    "run_id",
    "requested_workers",
    "placed_workers",
    "shortfall",
    "start_epoch",
    "target_rate",
    "rate_per_worker",
    "effective_offered_rate",
    "interruptible_workers",
    "comparable_to_baseline",
)

# Placeholders this tool knows how to fill. An unresolved placeholder is a
# contract that has grown a field this tool does not supply, and the right
# response is to fail rather than to write an object at a key containing a
# literal brace - which lands outside every partition the catalogue projects
# and is therefore invisible to every query.
KNOWN_PLACEHOLDERS = ("{dt}", "{run_id}")


class PublishError(RuntimeError):
    """Raised when the row cannot be published as a row the catalogue will read."""


def partition_date(start_epoch: int) -> str:
    """The run's partition, in UTC.

    UTC rather than local time because the projection generates its dates in
    UTC at query time. A row written under a local date is findable only by a
    reader who makes the same mistake.
    """
    return time.strftime("%Y-%m-%d", time.gmtime(start_epoch))


def resolve_key(template: str, *, dt: str, run_id: str) -> str:
    """Fill the contract's key template.

    Substituted rather than formatted. str.format would also interpret any
    other brace in the template, and the measurement template legitimately
    carries placeholders this tool has no values for - so a formatting call
    that happened to be given the wrong template would raise a KeyError about
    a field name instead of being refused here.
    """
    key = template.replace("{dt}", dt).replace("{run_id}", run_id)
    if "{" in key or "}" in key:
        raise PublishError(
            f"the key template {template!r} has placeholders this tool does not fill; "
            f"it knows {', '.join(KNOWN_PLACEHOLDERS)}. An unfilled placeholder would put the "
            "object outside every projected partition, where no query can see it."
        )
    return key


def validate(report: dict[str, Any]) -> None:
    missing = [field for field in REQUIRED_FIELDS if report.get(field) is None]
    if missing:
        raise PublishError(
            f"the report is missing {', '.join(missing)}. Each one is a figure a comparison "
            "depends on, and a row carrying a null in place of it reads like a run that was "
            "never judged rather than one that was never recorded."
        )
    if not isinstance(report["comparable_to_baseline"], bool):
        raise PublishError(
            "comparable_to_baseline must be a boolean. A truthy string is true to every reader "
            "that tests it, which turns a run that should not be compared into one that is."
        )
    if not isinstance(report["run_id"], str) or not report["run_id"].strip():
        raise PublishError("run_id must be a non-empty string.")
    if int(report["start_epoch"]) <= 0:
        raise PublishError("start_epoch must be a positive epoch second.")


def build_row(
    report: dict[str, Any],
    *,
    cluster: str | None,
    task_definition: str | None,
    scenario: str | None,
    now: float | None = None,
) -> dict[str, Any]:
    """The report, plus what the catalogue needs and the launcher does not know.

    The task definition is carried because its revision is the provenance of
    the generator code: it is what says which program produced a number. It is
    the first half of a result's provenance; the second is the contract version
    each worker records in its own measurements, which this tool cannot know
    because the workers read it after the launch.
    """
    validate(report)
    row = dict(report)
    row["schema_version"] = SCHEMA_VERSION
    row["written_at_epoch_ms"] = int((time.time() if now is None else now) * 1000)
    row["cluster"] = cluster
    row["task_definition"] = task_definition
    row["scenario"] = scenario
    row.setdefault("load_model", None)
    return row


def read_contract(parameter_name: str, region: str | None) -> dict[str, Any]:
    import boto3  # imported here so a dry run needs nothing installed

    client = boto3.client("ssm", region_name=region)
    response = client.get_parameter(Name=parameter_name)
    contract = json.loads(response["Parameter"]["Value"])
    version = response["Parameter"]["Version"]
    LOG.info("read result contract %s version %s", parameter_name, version)
    return contract


def put_row(bucket: str, key: str, row: dict[str, Any], region: str | None) -> None:
    import boto3

    client = boto3.client("s3", region_name=region)
    # One JSON object, newline terminated. The catalogue reads newline
    # delimited JSON, and a document pretty-printed across several lines is
    # read as several malformed records rather than as one good one.
    body = (json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    client.put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/json")
    LOG.info("wrote s3://%s/%s (%d bytes)", bucket, key, len(body))


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--report",
        default="-",
        help="Launcher report as JSON; '-' reads standard input (the default).",
    )
    parser.add_argument(
        "--contract-parameter",
        help="Parameter holding the result contract. The bucket and key template are read from it "
        "so that the layout exists in one place.",
    )
    parser.add_argument("--bucket", help="Override the bucket from the contract.")
    parser.add_argument("--key-template", help="Override the index key template from the contract.")
    parser.add_argument("--cluster", help="Cluster the fleet was placed in.")
    parser.add_argument(
        "--task-definition",
        help="Task definition including its revision. The revision is the provenance of the "
        "generator code.",
    )
    parser.add_argument("--scenario", help="Scenario the fleet was launched with.")
    parser.add_argument("--region", help="Region for the parameter and the bucket.")
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually write the object. Without it the row is printed and nothing is sent.",
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
        raw = sys.stdin.read() if args.report == "-" else open(args.report, encoding="utf-8").read()
    except OSError as error:
        LOG.error("cannot read the report: %s", error)
        return 2

    try:
        report = json.loads(raw)
    except json.JSONDecodeError as error:
        LOG.error("the report is not JSON: %s", error)
        return 2
    if not isinstance(report, dict):
        LOG.error("the report must be a JSON object; got %s", type(report).__name__)
        return 2

    bucket = args.bucket
    key_template = args.key_template

    if (bucket is None or key_template is None) and args.contract_parameter:
        try:
            contract = read_contract(args.contract_parameter, args.region)
        except Exception as error:  # the SDK raises its own exception types
            LOG.error("cannot read the result contract: %s", error)
            return 2
        bucket = bucket or contract.get("bucket")
        key_template = key_template or contract.get("index_key")

    if not bucket or not key_template:
        LOG.error(
            "no bucket or key template: pass --contract-parameter, or both --bucket and "
            "--key-template. Neither is defaulted here, because a layout written in two places "
            "is a layout that can stop matching the catalogue silently."
        )
        return 2

    try:
        row = build_row(
            report,
            cluster=args.cluster,
            task_definition=args.task_definition,
            scenario=args.scenario,
        )
        key = resolve_key(key_template, dt=partition_date(int(row["start_epoch"])), run_id=row["run_id"])
    except (PublishError, KeyError, TypeError, ValueError) as error:
        LOG.error("%s", error)
        return 1

    print(json.dumps({"bucket": bucket, "key": key, "row": row}, indent=2, sort_keys=True))

    if not args.execute:
        LOG.info("dry run: nothing written. Pass --execute to publish this row.")
        return 0

    try:
        put_row(bucket, key, row, args.region)
    except Exception as error:
        LOG.error("the row was not written: %s", error)
        return 1

    if not row["comparable_to_baseline"]:
        LOG.warning(
            "run %s is marked not comparable: %d worker(s) short and %d on reclaimable capacity. "
            "The measurements are stored; a comparison against a baseline is not valid.",
            row["run_id"],
            int(row["shortfall"]),
            int(row["interruptible_workers"]),
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
