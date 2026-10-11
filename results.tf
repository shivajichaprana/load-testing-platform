# ---------------------------------------------------------------------------
# The results pipeline
#
# A run is a distributed measurement. Every worker measures a sample of the
# same experiment, and the run's figure belongs to none of them - which is the
# property that decides almost everything below.
#
# Two consequences do most of the work.
#
#   A percentile cannot be combined across workers. Counts add and sums add,
#   but the mean of twenty workers' 95th percentiles is not the fleet's 95th
#   percentile and bears no stated relation to it: it lies somewhere between
#   the smallest and the largest of them, and so does every other number in
#   that interval. A pipeline that averages them produces a latency figure
#   that is wrong by an unknown amount and reads exactly like a correct one.
#   So each worker publishes a DISTRIBUTION over a shared ladder of bucket
#   boundaries, and the run's percentile is read off the merged distribution.
#   Buckets are what make the merge arithmetic rather than a guess.
#
#   The figure a run is judged against is a percentile near the latency
#   ceiling, and a bucketed percentile is only as precise as the bucket that
#   straddles it. The ladder therefore has to carry a boundary AT the ceiling,
#   and that is checked rather than documented.
#
# The pipeline has two halves because the two questions have different shapes.
# Metrics answer "what is happening now" for a fleet whose runs are not known
# when the dashboard is written. Objects in S3, catalogued and queried, answer
# "what happened in that run" and "how does it compare" - questions that name
# a run and that no amount of dashboard can answer, because a metric
# dimensioned by run identifier is a new metric for every run.
# ---------------------------------------------------------------------------

locals {
  # The bucket is created here unless one was supplied. A supplied bucket is
  # adopted rather than configured: its encryption, versioning and lifecycle
  # belong to whoever owns it, so none of the hardening below is applied to it
  # and the findings say so.
  manage_results_bucket = var.run_artifact_bucket_name == null

  results_bucket_name = coalesce(
    var.run_artifact_bucket_name,
    "${var.name_prefix}-results-${data.aws_caller_identity.current.account_id}",
  )

  # A bucket name is capped at 63 characters. name_prefix is independently
  # capped at 20, and the generated suffix is fixed, so the derived name cannot
  # currently exceed the cap. It is asserted for the edit that lengthens the
  # suffix.
  results_bucket_name_budget = 63

  # The layout, in one place. Every consumer below is built from these: the
  # table locations, the key template handed to the workers, the lifecycle
  # filters and the write permission. A layout written twice is a layout that
  # agrees until one of the two is edited.
  #
  # Everything a worker writes is under results_root, which is what the task
  # role's write grant is scoped to. Query output deliberately is NOT: a
  # worker that could write where query results land could overwrite the
  # answer to a question about itself.
  results_root         = "${var.name_prefix}/runs"
  samples_prefix       = "${local.results_root}/samples"
  index_prefix         = "${local.results_root}/index"
  query_results_prefix = "${var.name_prefix}/query-results"

  # Hive-style partition directories, in the order the catalog declares them.
  # The emitter is given the whole template rather than its pieces, because a
  # key assembled at both ends is a key the catalog can stop recognising
  # without anything failing: objects land, the table reports no rows, and the
  # run looks like one that offered no load.
  #
  # The key carries the worker's TASK IDENTIFIER and a flush sequence, and it
  # needs both. A key naming only the worker is overwritten by that worker's
  # next flush; a key naming only the sequence is overwritten by every other
  # worker's flush of the same index. Neither overwrite is an error - a PUT to
  # an existing key succeeds - so a run would report the workers it placed and
  # silently hold one worker's results.
  #
  # It is a task identifier rather than an index because one launch request
  # places identical tasks: every task in a request receives the same
  # overrides, so no worker can be told which one it is, and the task metadata
  # inside the container is the only per-worker fact available.
  sample_key_template = "${local.samples_prefix}/dt={dt}/run_id={run_id}/t{task_id}-{flush_seq}.json.gz"
  index_key_template  = "${local.index_prefix}/dt={dt}/{run_id}.json"

  catalog_database_name = coalesce(var.catalog_database_name, replace("${var.name_prefix}_results", "-", "_"))

  # Table names are literals rather than derived, because the committed SQL
  # names them and a derived name would put the same string in two places. The
  # guards below check the SQL against these, which is what keeps the two in
  # step.
  samples_table = "run_samples"
  index_table   = "run_index"

  # Three retention figures, all derived from one, all published - because they
  # are different lengths and the differences are the kind that get discovered
  # by a query returning fewer rows than it should.
  #
  #   queryable: the window the partition projection offers. Deliberately one
  #     calendar date SHORTER than the expiry, because lifecycle expiry is not
  #     instantaneous: at the boundary a partition may be whole, part-deleted
  #     or empty, and a part-deleted partition answers a query with a smaller
  #     number and no error. Stopping the projection first means a partition
  #     the query can see is one that was never due for deletion.
  #
  #   expiry: when the current version of an object stops being current.
  #
  #   storage: when the bytes actually go. On a versioned bucket an expiry
  #     makes the current version noncurrent rather than deleting it, so the
  #     real lifetime is the expiry plus the noncurrent window, and the cost
  #     is carried for the sum rather than for the first figure.
  queryable_days = var.results_retention_days - 1
  storage_days   = var.results_retention_days + var.results_noncurrent_version_retention_days
}

# ---------------------------------------------------------------------------
# Results bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "results" {
  count = local.manage_results_bucket ? 1 : 0

  bucket = local.results_bucket_name

  # Off by default. The contents are a measurement history, and a destroy that
  # silently empties it removes the baselines every later comparison is made
  # against - which is a quieter loss than a failed destroy.
  force_destroy = var.results_bucket_force_destroy
}

resource "aws_s3_bucket_public_access_block" "results" {
  count = local.manage_results_bucket ? 1 : 0

  bucket = aws_s3_bucket.results[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "results" {
  count = local.manage_results_bucket ? 1 : 0

  bucket = aws_s3_bucket.results[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Encryption is the platform-managed key rather than a customer-managed one,
# and that is a cost decision with a stated figure rather than a default taken
# unexamined. Every object written costs a key operation, and the object count
# here is the fleet size multiplied by the run length divided by the flush
# interval - so a customer-managed key bills per flush of per worker, and a
# large fleet flushing on the same interval arrives as a burst against the key
# service's own request rate. A bucket key amortises that, and is the first
# thing to set if a customer-managed key is required by policy.
resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  count = local.manage_results_bucket ? 1 : 0

  bucket = aws_s3_bucket.results[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

# Versioning is on for one reason, and it is not rollback. The key template is
# built to be unique per worker and per flush; if that uniqueness is ever
# broken, the second write SUCCEEDS and the first worker's results vanish with
# nothing reported. A version history is the only place that collision is
# visible afterwards.
resource "aws_s3_bucket_versioning" "results" {
  count = local.manage_results_bucket ? 1 : 0

  bucket = aws_s3_bucket.results[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  count = local.manage_results_bucket ? 1 : 0

  bucket = aws_s3_bucket.results[0].id

  # Results are streamed DURING a run, and a worker on interruptible capacity
  # can be taken away mid-upload. An abandoned multipart upload is billed for
  # its parts and appears in no object listing, so nothing in the bucket's
  # contents suggests it exists - and the task role deliberately cannot delete,
  # so this rule is the only thing in the account that will ever clean one up.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  # Expiry of the run history. On a versioned bucket this makes the current
  # version noncurrent; the next rule is what removes the bytes.
  rule {
    id     = "expire-run-history"
    status = "Enabled"

    filter {
      prefix = "${local.results_root}/"
    }

    expiration {
      days = var.results_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.results_noncurrent_version_retention_days
    }
  }

  # A separate rule because expired_object_delete_marker and a days-based
  # expiration cannot share one: the API rejects the pair. Without this, every
  # expired object leaves a delete marker behind for good, and a prefix whose
  # objects are all gone still costs a listing that walks them.
  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"

    filter {
      prefix = "${local.results_root}/"
    }

    expiration {
      expired_object_delete_marker = true
    }
  }

  # Query output. Each query leaves a result object and a metadata object
  # behind, forever, and nothing in the query engine removes them: the bill for
  # a year of exploratory queries is paid in storage rather than in scans.
  rule {
    id     = "expire-query-results"
    status = "Enabled"

    filter {
      prefix = "${local.query_results_prefix}/"
    }

    expiration {
      days = var.query_result_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.results]
}

# ---------------------------------------------------------------------------
# The result contract
#
# What a worker needs in order to write a result that the catalogue can read:
# the bucket, the key template, the flush interval, the bucket ladder and how
# the metrics are published. It is delivered as a parameter rather than on the
# task definition because the task definition's revision is cited as the
# provenance of the GENERATOR, and these values are the provenance of the
# AGGREGATION - a different fact, which can change without the generator
# changing and must not be able to change without being recorded.
#
# So the parameter's version is the second half of a result's provenance, and
# every sample object records the version it was written under. Nothing stops
# the parameter being updated between a launch and a worker's read of it, which
# is exactly why the worker records what it read rather than the configuration
# recording what it published.
#
# Plain String, not an encrypted parameter: encrypting it puts a key policy on
# the worker's read path, and a worker that cannot read this does not know
# where to write - so it has no way to report that it could not report.
# ---------------------------------------------------------------------------

locals {
  # Dimension names, declared once. They reach three places - the contract the
  # workers read, the dashboards' metric entries, and the publish permission's
  # namespace scope - and a name that differs between any two of them produces
  # a dashboard that applied cleanly and renders blank.
  fleet_dimension_name = "Fleet"
  phase_dimension_name = "Phase"

  # The metric catalogue. One definition with three consumers: this contract,
  # the dashboards, and the published outputs. A dashboard naming a metric the
  # workers do not publish renders empty and applies cleanly, so the only
  # defence is that neither side carries its own list.
  #
  # `source` names the generator metric each one is published FROM. It is the
  # mapping between the two halves of the pipeline: these names are what
  # CloudWatch carries, and the source names are what the committed SQL reads
  # out of the object store. The guards below check the SQL against this
  # column, so a query asking for a metric nothing emits fails the plan rather
  # than returning an empty result set months later.
  result_metrics = {
    RequestsCompleted = {
      kind       = "counter"
      unit       = "Count"
      stat       = "Sum"
      source     = "http_reqs"
      dimensions = [local.fleet_dimension_name, local.phase_dimension_name]
      about      = "Requests that received a response the target meant to send."
    }
    RequestsFailed = {
      kind       = "counter"
      unit       = "Count"
      stat       = "Sum"
      source     = "http_reqs"
      dimensions = [local.fleet_dimension_name, local.phase_dimension_name]
      about      = "Requests that did not. Includes connection-level failures, which are the fleet's own saturation as often as the target's."
    }
    IterationsDropped = {
      kind       = "counter"
      unit       = "Count"
      stat       = "Sum"
      source     = "dropped_iterations"
      dimensions = [local.fleet_dimension_name, local.phase_dimension_name]
      about      = "Iterations the generator could not start. A run that dropped any did not offer the rate it reports."
    }
    RequestDuration = {
      kind       = "trend"
      unit       = "Milliseconds"
      stat       = "p95"
      source     = "http_req_duration"
      dimensions = [local.fleet_dimension_name, local.phase_dimension_name]
      about      = "Response time over the shared bucket ladder, for responses the target meant to send."
    }
    ConnectionsHeld = {
      kind       = "gauge"
      unit       = "Count"
      stat       = "Maximum"
      source     = "connections_held"
      dimensions = [local.fleet_dimension_name]
      about      = "Four-tuples one worker holds at once, against the socket budget the fleet size was divided by."
    }
    VirtualUsersActive = {
      kind       = "gauge"
      unit       = "Count"
      stat       = "Maximum"
      source     = "vus"
      dimensions = [local.fleet_dimension_name]
      about      = "Population actually in use, as distinct from the population pre-allocated."
    }
    WorkerFlushes = {
      kind       = "counter"
      unit       = "Count"
      stat       = "Sum"
      source     = "worker_flushes"
      dimensions = [local.fleet_dimension_name]
      about      = "One per worker per flush. Divided by the flushes a period contains, this is how many workers are reporting - and a fall mid-run is a withdrawn worker rather than a slower target."
    }
    ChecksPassed = {
      kind       = "counter"
      unit       = "Count"
      stat       = "Sum"
      source     = "checks_passed"
      dimensions = [local.fleet_dimension_name, local.phase_dimension_name]
      about      = "Named assertions that held. Evidence, not a verdict: a check records a result and does not fail a run."
    }
    ChecksFailed = {
      kind       = "counter"
      unit       = "Count"
      stat       = "Sum"
      source     = "checks_failed"
      dimensions = [local.fleet_dimension_name, local.phase_dimension_name]
      about      = "Named assertions that did not. Binding only where a threshold was scoped to the same name and phase."
    }
  }

  trend_metric_names = sort([for name, m in local.result_metrics : name if m.kind == "trend"])

  # Dimensions are chosen so that a dashboard written before any run exists can
  # still name them. Fleet is this deployment; Phase comes from the scenario
  # library's own profiles. Deliberately NOT the run identifier: a dimension
  # combination IS the metric, so dimensioning by run creates a fresh custom
  # metric per run, each billed for the calendar month although it was alive
  # for minutes, and none of them nameable in advance. Run attribution lives in
  # the object store, where it costs a prefix.
  stable_dimensions = {
    (local.fleet_dimension_name) = var.name_prefix
  }

  # Read out of the scenario library rather than restated here, so the set a
  # dashboard charts is the set a run can emit. A refactor that changes how the
  # phases are written stops this matching and fails the plan, which is the
  # loud failure; a copy of the list here would keep charting a phase the
  # library no longer has.
  phase_names = sort(distinct([
    for m in regexall("phase:\\s*'([a-z]+)'", file("${path.module}/scenarios/lib/stages.js")) : m[0]
  ]))

  result_contract = {
    schema_version = 1
    bucket         = local.results_bucket_name
    samples_key    = local.sample_key_template
    index_key      = local.index_key_template
    flush_seconds  = var.result_flush_seconds
    compression    = "gzip"
    record_format  = "json-lines"
    # The ladder, shared by every worker. Two runs aggregated over different
    # ladders are not comparable at any percentile, which is why this travels
    # with a version rather than as a default inside the image.
    latency_buckets_ms = var.latency_bucket_boundaries_ms
    latency_ceiling_ms = var.latency_ceiling_ms
    metric_namespace   = var.metric_namespace
    metric_publish     = var.metric_publish_mode
    metric_resolution  = var.metric_resolution_seconds
    dimensions         = local.stable_dimensions
    metrics = {
      for name, m in local.result_metrics : name => {
        kind       = m.kind
        unit       = m.unit
        source     = m.source
        dimensions = m.dimensions
      }
    }
  }

  result_contract_json = jsonencode(local.result_contract)

  # A Standard-tier parameter holds 4 KB. The Advanced tier holds more and is
  # billed per parameter per month, which is the wrong trade for one document,
  # so the document is kept inside the free bound and the bound is checked.
  #
  # Worth stating which part of the document the bound actually constrains,
  # because it is not the obvious one. The ladder is separately capped at 150
  # boundaries, and a full ladder of five-digit figures brings the whole
  # document to about 1.3 KB with no metrics in it at all - so the ladder
  # cannot breach this by itself. The metric catalogue can: alongside a full
  # ladder it runs out of room at the 26th metric.
  contract_size_budget = 4096
}

resource "aws_ssm_parameter" "result_contract" {
  name        = "/${var.name_prefix}/run/results/contract"
  description = "Where a worker writes its results and how it aggregates them. The version is half of a result's provenance."
  type        = "String"
  tier        = "Standard"
  value       = local.result_contract_json

  lifecycle {
    precondition {
      condition     = length(local.result_contract_json) <= local.contract_size_budget
      error_message = "The result contract is ${length(local.result_contract_json)} bytes against the ${local.contract_size_budget}-byte Standard parameter tier. Two parts of it grow, and not equally: a ladder at its own 150-boundary cap brings the document to about 1.3 KB with no metrics in it, so the ladder cannot breach this by itself - in practice the bound is on the METRIC CATALOGUE, which runs out of room at the 26th metric alongside a full ladder. Shorten whichever grew, or move the parameter to the Advanced tier deliberately and accept its monthly charge."
    }
  }
}

# ---------------------------------------------------------------------------
# Catalogue
#
# Partition projection rather than registered partitions. The alternative is a
# crawler or an explicit partition registration per run, and both put a WRITE
# in the path of a run finishing: a run whose partition was never registered
# has results in the bucket and no rows in the table, which reads as a run that
# measured nothing. Projection computes the partitions from the table's own
# properties instead, so a result is queryable the moment the object lands.
#
# Note what projection costs: a table with projection enabled IGNORES any
# partition metadata registered to it. Turning it on is therefore not additive
# - anything that registered partitions before stops contributing.
# ---------------------------------------------------------------------------

locals {
  # Partition columns, declared once and in order. The projection properties
  # below are built from this, so a column cannot be added without its
  # projection configuration - which is otherwise a query-time failure naming
  # the metastore rather than the edit.
  sample_partitions = {
    dt = {
      type    = "date"
      comment = "Calendar date of the measurement window, in UTC."
      properties = {
        format          = "yyyy-MM-dd"
        interval        = "1"
        "interval.unit" = "DAYS"
        range           = "NOW-${local.queryable_days}DAYS,NOW"
      }
    }
    run_id = {
      type       = "injected"
      comment    = "Run identifier. Injected: a query must filter on it."
      properties = {}
    }
  }

  sample_partition_order = ["dt", "run_id"]

  index_partitions = {
    dt = {
      type    = "date"
      comment = "Calendar date the run was launched on, in UTC."
      properties = {
        format          = "yyyy-MM-dd"
        interval        = "1"
        "interval.unit" = "DAYS"
        range           = "NOW-${local.queryable_days}DAYS,NOW"
      }
    }
  }

  index_partition_order = ["dt"]

  projection_properties = {
    for table, partitions in {
      (local.samples_table) = local.sample_partitions
      (local.index_table)   = local.index_partitions
      } : table => merge(
      { "projection.enabled" = "true" },
      merge([
        for column, spec in partitions : merge(
          { "projection.${column}.type" = spec.type },
          { for key, value in spec.properties : "projection.${column}.${key}" => value },
        )
      ]...),
    )
  }

  # Serde options, both of them decisions.
  #
  # Malformed records FAIL the query. The permissive setting skips the line and
  # answers anyway, which here means a worker's results are dropped and the
  # query returns a smaller number with no indication that it did - the same
  # failure as a threshold whose selector matched nothing.
  #
  # Case folding is off. The emitter writes lowercase keys, so nothing needs
  # folding, and one column is a map whose KEYS are task identifiers rather
  # than field names: folding an identifier is not a formatting change.
  serde_parameters = {
    "ignore.malformed.json" = "FALSE"
    "case.insensitive"      = "FALSE"
  }

  json_serde = "org.openx.data.jsonserde.JsonSerDe"
}

resource "aws_glue_catalog_database" "results" {
  name        = local.catalog_database_name
  description = "Run history for the load fleet: per-worker measurement windows and the launcher's placement record."
}

resource "aws_glue_catalog_table" "run_samples" {
  name          = local.samples_table
  database_name = aws_glue_catalog_database.results.name
  table_type    = "EXTERNAL_TABLE"
  description   = "One row per measurement window, per worker, per metric, per tag set. Counts and sums combine across workers; percentiles are read off the merged bucket ladder."

  parameters = merge(
    local.projection_properties[local.samples_table],
    {
      "EXTERNAL"           = "TRUE"
      "classification"     = "json"
      "compressionType"    = "gzip"
      "has_encrypted_data" = "false"
    },
  )

  dynamic "partition_keys" {
    for_each = local.sample_partition_order

    content {
      name    = partition_keys.value
      type    = "string"
      comment = local.sample_partitions[partition_keys.value].comment
    }
  }

  storage_descriptor {
    location      = "s3://${local.results_bucket_name}/${local.samples_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = true

    ser_de_info {
      serialization_library = local.json_serde
      parameters            = local.serde_parameters
    }

    # Provenance.
    columns {
      name    = "contract_version"
      type    = "int"
      comment = "Version of the result contract this worker read. Two runs are comparable only if they agree."
    }
    columns {
      name    = "task_id"
      type    = "string"
      comment = "The worker's own identity. Not an index: one launch request places identical tasks, so no worker can be told which one it is."
    }

    # The measurement window. An epoch integer rather than a timestamp column:
    # the value in the file is parsed by the serde and not by the query engine,
    # and the catalogue's types are Hive's while a query's are the engine's. An
    # integer means the same thing to both.
    columns {
      name    = "window_start_epoch_ms"
      type    = "bigint"
      comment = "Start of the aggregation window, epoch milliseconds, UTC."
    }
    columns {
      name    = "window_seconds"
      type    = "int"
      comment = "Length of the window. Published per row because it is the divisor for every rate the queries compute."
    }

    # What was run.
    columns {
      name    = "scenario"
      type    = "string"
      comment = "Scenario file the worker executed."
    }
    columns {
      name    = "profile"
      type    = "string"
      comment = "Load profile from the scenario library."
    }
    columns {
      name    = "load_model"
      type    = "string"
      comment = "open or closed. Under the closed model throughput is an output, so a rate from it answers a different question."
    }

    # The metric and its shape.
    columns {
      name    = "metric"
      type    = "string"
      comment = "Generator metric name, for example http_req_duration."
    }
    columns {
      name    = "metric_kind"
      type    = "string"
      comment = "counter, gauge or trend. Decides which of the value columns carry anything."
    }

    # Tags. Every one of these is a dimension a figure can be scoped to, and
    # two of them are load-bearing rather than descriptive: phase keeps the
    # ramp out of a percentile, and expected_response keeps fast rejections out
    # of it - an error response is cheaper than a correct one, so an unscoped
    # percentile IMPROVES as a target starts failing.
    columns {
      name    = "phase"
      type    = "string"
      comment = "Phase of the profile this window fell in."
    }
    columns {
      name    = "name"
      type    = "string"
      comment = "Grouped request name. Not the URL: a URL carrying an identifier produces one series per request."
    }
    columns {
      name    = "method"
      type    = "string"
      comment = "Request method."
    }
    columns {
      name    = "status"
      type    = "string"
      comment = "Response status, as text. Absent for a request that never got one."
    }
    columns {
      name    = "expected_response"
      type    = "boolean"
      comment = "Whether the target meant to send this response. A real boolean, so a typo in a filter is a type error rather than a predicate that matches nothing."
    }
    columns {
      name    = "error_code"
      type    = "string"
      comment = "Generator error class for a request that failed below the protocol. This is where fleet saturation shows up."
    }
    columns {
      name    = "check_name"
      type    = "string"
      comment = "Named assertion, for check results. A check RECORDS a result and does not fail a run, so a pass rate here is only binding where a threshold covers it."
    }

    # Values.
    columns {
      name    = "sample_count"
      type    = "bigint"
      comment = "Observations in this window. Adds across workers."
    }
    columns {
      name    = "value"
      type    = "double"
      comment = "Counter increment or gauge reading. Null for a trend."
    }
    columns {
      name    = "sum_ms"
      type    = "double"
      comment = "Sum of observations, for a trend. Adds across workers, which is why a mean does and a percentile does not."
    }
    columns {
      name    = "min_ms"
      type    = "double"
      comment = "Smallest observation in the window."
    }
    columns {
      name    = "max_ms"
      type    = "double"
      comment = "Largest observation in the window. The only exact tail figure the pipeline has."
    }
    columns {
      name    = "buckets"
      type    = "array<struct<le_ms:double,sample_count:bigint>>"
      comment = "Non-cumulative counts over the shared ladder. le_ms is the bucket's inclusive upper bound; the cumulative sum is taken in the query so the ladder can change without rewriting history."
    }
  }
}

resource "aws_glue_catalog_table" "run_index" {
  name          = local.index_table
  database_name = aws_glue_catalog_database.results.name
  table_type    = "EXTERNAL_TABLE"
  description   = "One row per run: what was asked for, what was placed, and whether the result may be compared against a baseline. Partitioned by date only, so finding runs needs no run identifier."

  parameters = merge(
    local.projection_properties[local.index_table],
    {
      "EXTERNAL"           = "TRUE"
      "classification"     = "json"
      "has_encrypted_data" = "false"
    },
  )

  dynamic "partition_keys" {
    for_each = local.index_partition_order

    content {
      name    = partition_keys.value
      type    = "string"
      comment = local.index_partitions[partition_keys.value].comment
    }
  }

  storage_descriptor {
    location      = "s3://${local.results_bucket_name}/${local.index_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = local.json_serde
      parameters            = local.serde_parameters
    }

    columns {
      name    = "schema_version"
      type    = "int"
      comment = "Version of this record's shape."
    }
    columns {
      name    = "run_id"
      type    = "string"
      comment = "Run identifier, as supplied to the workers."
    }
    columns {
      name    = "written_at_epoch_ms"
      type    = "bigint"
      comment = "When the record was published, which is after the launch and before the run ends."
    }
    columns {
      name    = "cluster"
      type    = "string"
      comment = "Cluster the fleet was placed in."
    }
    columns {
      name    = "task_definition"
      type    = "string"
      comment = "Task definition including its revision. The revision is the provenance of the generator code."
    }
    columns {
      name    = "scenario"
      type    = "string"
      comment = "Scenario the fleet was launched with."
    }
    columns {
      name    = "load_model"
      type    = "string"
      comment = "open or closed."
    }
    columns {
      name    = "requested_workers"
      type    = "int"
      comment = "Workers the objective derived."
    }
    columns {
      name    = "placed_workers"
      type    = "int"
      comment = "Workers that actually exist. A successful launch response can carry placement failures, so this is reconciled rather than assumed."
    }
    columns {
      name    = "shortfall"
      type    = "int"
      comment = "Requested minus placed. A shortfall means the run offered less load than its target says."
    }
    columns {
      name    = "start_epoch"
      type    = "bigint"
      comment = "The synchronized start instant every worker waited for."
    }
    columns {
      name    = "target_rate"
      type    = "double"
      comment = "Fleet arrival rate asked for."
    }
    columns {
      name    = "rate_per_worker"
      type    = "double"
      comment = "Uniform share handed to each worker. Uniform because one request places identical tasks."
    }
    columns {
      name    = "effective_offered_rate"
      type    = "double"
      comment = "Share multiplied by the workers that exist. This, not target_rate, is what the run offered."
    }
    columns {
      name    = "interruptible_workers"
      type    = "int"
      comment = "Workers on reclaimable capacity. A reclaimed worker withdraws its load mid-run, which the target's metrics cannot distinguish from the target degrading."
    }
    columns {
      name    = "comparable_to_baseline"
      type    = "boolean"
      comment = "False when the fleet was short or partly interruptible. A comparison against a baseline is void in either case."
    }
    columns {
      name    = "worker_index"
      type    = "map<string,int>"
      comment = "Index assigned to each placed worker after the fact, for the record only. Keys are task ARNs."
    }
    columns {
      name    = "capacity_providers"
      type    = "map<string,string>"
      comment = "Which capacity each placed worker landed on."
    }
    columns {
      name    = "failures"
      type    = "array<struct<arn:string,reason:string,detail:string>>"
      comment = "Placement failures returned alongside the successes."
    }
  }
}

# ---------------------------------------------------------------------------
# Query workgroup
#
# The workgroup exists to put two bounds on exploration rather than to organise
# it. A scan cutoff, because the whole point of a run-history table is that it
# accumulates and the cost of reading all of it is paid by whoever typed the
# query. And enforced configuration, because the setting that matters most is
# where results land: a client that can redirect them writes the answer to a
# question about this account somewhere this account does not control.
# ---------------------------------------------------------------------------

resource "aws_athena_workgroup" "results" {
  name        = "${var.name_prefix}-results"
  description = "Run history for the load fleet. Scan-bounded, with results confined to the fleet's own bucket."
  state       = "ENABLED"

  # The named queries below are generated from committed files, so refusing to
  # destroy a workgroup that holds them protects nothing that is not in version
  # control.
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.query_scan_cutoff_bytes
    requester_pays_enabled             = false

    result_configuration {
      output_location = "s3://${local.results_bucket_name}/${local.query_results_prefix}/"

      # Refuses to write results into a bucket that has changed hands. Cheap,
      # and the failure it prevents is silent.
      expected_bucket_owner = data.aws_caller_identity.current.account_id

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Named queries
#
# Registered FROM the committed files rather than written out here, so the text
# in the console is the text in version control. Adding a file registers it;
# there is no list to keep in step.
#
# The files name their tables without a database qualifier on purpose: the
# database name is chosen by this configuration, and a qualified name in the
# file would be that choice written a second time. Each named query carries the
# database instead.
# ---------------------------------------------------------------------------

locals {
  query_files = fileset("${path.module}/queries", "*.sql")

  queries = {
    for f in local.query_files : trimsuffix(f, ".sql") => {
      body = file("${path.module}/queries/${f}")
      # The first line of every file is its one-line summary, which becomes the
      # description. One place again: a description written here would be a
      # second summary that agrees with the file until one is edited.
      summary = trimspace(trimprefix(trimspace(split("\n", file("${path.module}/queries/${f}"))[0]), "--"))
    }
  }

  # A query against the samples table MUST filter on the run identifier. That
  # column is an injected projection, and a query with no filter expression for
  # it does not return everything - it fails. Checked here because the failure
  # otherwise arrives in a console, to whoever ran the query, months later.
  queries_missing_run_filter = sort([
    for name, q in local.queries : name
    if strcontains(q.body, local.samples_table) && !strcontains(q.body, "run_id")
  ])

  queries_missing_summary = sort([
    for name, q in local.queries : name
    if q.summary == "" || length(q.summary) > 1024
  ])

  # Generator metric names the committed SQL asks for, read out of the SQL
  # itself. Every metric predicate in the catalogue is written as an equality
  # against a literal precisely so that this extraction is sound; a predicate
  # written some other way would pass unchecked, which is why the convention is
  # stated in the query README rather than left to be noticed.
  known_metric_sources = toset([for name, m in local.result_metrics : m.source])

  queried_metric_sources = toset(flatten([
    for name, q in local.queries : [
      for m in regexall("metric\\s*=\\s*'([a-z_]+)'", q.body) : m[0]
    ]
  ]))

  unknown_queried_metrics = sort(setsubtract(local.queried_metric_sources, local.known_metric_sources))

  # The other direction. A metric the pipeline publishes that nothing asks for
  # is not a fault, but it is worth knowing: it is being paid for in custom
  # metric charges and in object size, and nothing reads it.
  unqueried_metric_sources = sort(setsubtract(local.known_metric_sources, local.queried_metric_sources))
}

resource "aws_athena_named_query" "catalog" {
  for_each = local.queries

  name        = "${var.name_prefix}-${each.key}"
  description = each.value.summary
  workgroup   = aws_athena_workgroup.results.id
  database    = aws_glue_catalog_database.results.name
  query       = each.value.body
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

resource "terraform_data" "results_preconditions" {
  # Fed the guarded values so the checks are evaluated whenever any of them
  # changes, rather than once at creation.
  input = {
    bucket    = local.results_bucket_name
    contract  = local.result_contract_json
    queryable = local.queryable_days
    queries   = sort(keys(local.queries))
  }

  lifecycle {
    precondition {
      condition     = length(local.results_bucket_name) <= local.results_bucket_name_budget
      error_message = "The derived results bucket name is ${length(local.results_bucket_name)} characters against the ${local.results_bucket_name_budget}-character limit on a bucket name. Shorten name_prefix, or supply run_artifact_bucket_name."
    }

    precondition {
      condition     = contains(var.latency_bucket_boundaries_ms, var.latency_ceiling_ms)
      error_message = "The bucket ladder has no boundary at the latency ceiling of ${var.latency_ceiling_ms} ms. A bucketed percentile is only as precise as the bucket straddling it, and the ceiling is the exact figure the run is judged against - so without a boundary there, the one number that decides the result is readable only to the width of a bucket. Add ${var.latency_ceiling_ms} to latency_bucket_boundaries_ms."
    }

    precondition {
      condition     = length(local.phase_names) >= 2 && contains(local.phase_names, "steady")
      error_message = "The phase set read out of the scenario library is ${jsonencode(local.phase_names)}, which does not look like a profile's phases. The set is extracted from the library rather than restated, so this means the library's shape changed: fix the extraction in locals rather than writing the list out here, or the dashboards will chart phases no run emits."
    }

    precondition {
      condition     = length(local.sample_partition_order) == length(local.sample_partitions) && alltrue([for c in local.sample_partition_order : contains(keys(local.sample_partitions), c)])
      error_message = "The declared partition order ${jsonencode(local.sample_partition_order)} does not cover the partition columns ${jsonencode(sort(keys(local.sample_partitions)))}. A partition column with no projection configuration fails at query time with an error naming the metastore rather than this edit."
    }

    precondition {
      condition     = !startswith("${local.query_results_prefix}/", "${local.results_root}/") && !startswith("${local.results_root}/", "${local.query_results_prefix}/")
      error_message = "The query output prefix ${local.query_results_prefix}/ and the run history prefix ${local.results_root}/ nest. Both are derived from name_prefix with fixed suffixes, so this cannot be reached by any input - it is here for the edit that changes a suffix. A table whose location contains its own query output reads its answers back as data, and a worker permitted to write under the run prefix could overwrite a query result."
    }

    precondition {
      condition     = length(local.queries_missing_run_filter) == 0
      error_message = "These queries read ${local.samples_table} without filtering on run_id: ${join(", ", local.queries_missing_run_filter)}. run_id is an injected partition column, and a query that supplies no filter expression for it FAILS rather than returning every run. Add a run predicate, or read the date-partitioned ${local.index_table} instead."
    }

    precondition {
      condition     = length(local.queries_missing_summary) == 0
      error_message = "These query files have no usable first-line summary: ${join(", ", local.queries_missing_summary)}. The first line must be a comment of at most 1024 characters; it becomes the registered query's description."
    }

    precondition {
      condition     = length(local.queries) > 0
      error_message = "No .sql files were found under queries/. The catalogue would be registered with nothing to ask it."
    }

    precondition {
      condition     = length(local.unknown_queried_metrics) == 0
      error_message = "The committed SQL asks for metric(s) nothing in the result contract produces: ${join(", ", local.unknown_queried_metrics)}. A predicate on a metric name no worker emits selects no rows, and a query over no rows returns NULL rather than failing - so the figure comes back empty and reads like a run that measured nothing."
    }

  }
}

# ---------------------------------------------------------------------------
# Findings about the pipeline
#
# As with the fleet's own findings, these are statements about what a run's
# results will MEAN rather than faults in the configuration. Each carries the
# figure it rests on.
# ---------------------------------------------------------------------------

locals {
  candidate_result_findings = [
    {
      code     = "R101"
      when     = true
      severity = "note"
      message = format(
        "The run history is queryable for %d calendar dates, the current version of an object expires after %d, and the bytes are gone after %d. The three are different lengths on purpose: the projection stops a date early so no visible partition is part-way through being deleted, and a versioned bucket keeps an expired object as a noncurrent version for the rest of the window, which is what the storage is billed for.",
        local.queryable_days,
        var.results_retention_days,
        local.storage_days,
      )
    },
    {
      code     = "R102"
      when     = var.metric_publish_mode != "values"
      severity = "warning"
      message = format(
        "Metrics are published as statistic sets, so no percentile is retrievable for the %d distribution metric(s) this pipeline publishes (%s): a statistic set answers a percentile only where every sample in it is the same value. The latency widgets fall back to a mean and a maximum, and the percentile the run is judged against has to come from the object store - which is where the merged bucket ladder lives anyway.",
        length(local.trend_metric_names),
        join(", ", local.trend_metric_names),
      )
    },
    {
      code     = "R103"
      when     = length(var.latency_bucket_boundaries_ms) > 150
      severity = "warning"
      message = format(
        "The bucket ladder has %d boundaries. One publish request carries at most 150 values for a metric, so a flush of this distribution needs more than one request and the halves of one window's distribution arrive as separate data points. Shorten the ladder, or accept that a percentile read from the metric stream is taken over part of the window.",
        length(var.latency_bucket_boundaries_ms),
      )
    },
    {
      code     = "R104"
      when     = local.derived_worker_count > 0 && var.result_flush_seconds > 0
      severity = "note"
      message = format(
        "At a %ds flush the fleet of %d workers writes about %.0f objects per hour of run time, and a worker taken away mid-flush loses up to %ds of its own measurements. Those are the two sides of this one figure: a longer interval means fewer objects for a query to open and more lost when a worker goes.",
        var.result_flush_seconds,
        local.derived_worker_count,
        local.derived_worker_count * 3600 / var.result_flush_seconds,
        var.result_flush_seconds,
      )
    },
    {
      code     = "R105"
      when     = length(local.unqueried_metric_sources) > 0
      severity = "note"
      message = format(
        "These metrics are written into the run history and no query in the catalogue reads them: %s. They are charted live on the fleet view, which is where a gauge is worth looking at - but it means a question about them AFTER a run has to be written by hand, and until it is, the only bound on how long it can be asked is the metric stream's own retention rather than the retention set for results.",
        join(", ", local.unqueried_metric_sources),
      )
    },
    {
      code     = "R106"
      when     = local.interruptible_share > 0
      severity = "warning"
      message  = "Part of the fleet is reclaimable, and results are streamed rather than written at the end precisely because of that. A reclaimed worker still loses whatever it had not flushed, and the launcher's record marks the whole run as not comparable - so the pipeline will store these results and refuse to compare them, which is the intended behaviour rather than a gap."
    },
    {
      # The threshold is written as arithmetic rather than as a bare literal:
      # 100 GiB in bytes is a twelve-digit integer, indistinguishable by
      # inspection from an account identifier.
      code     = "R107"
      when     = var.query_scan_cutoff_bytes >= 100 * 1073741824
      severity = "note"
      message = format(
        "The per-query scan cutoff is %.0f GiB. The table grows for as long as the retention allows, and the cutoff is the only thing standing between an exploratory query and reading all of it, so it is worth setting to the size of a few runs rather than to the size of the history.",
        var.query_scan_cutoff_bytes / 1073741824,
      )
    },
    {
      code     = "R108"
      when     = var.log_retention_in_days < var.results_retention_days
      severity = "warning"
      message = format(
        "Runner logs are kept %d days against %d days of results. A run's numbers will outlive the only record of what the fleet was doing while it produced them - which is the record that says whether a worker was reclaimed, started late, or refused its own launch contract.",
        var.log_retention_in_days,
        var.results_retention_days,
      )
    },
  ]

  result_findings = [
    for f in local.candidate_result_findings : {
      code     = f.code
      severity = f.severity
      message  = f.message
    } if f.when
  ]

  result_warnings = [for f in local.result_findings : f if f.severity == "warning"]
}

check "results_pipeline_has_no_warnings" {
  assert {
    condition     = length(local.result_warnings) == 0
    error_message = "The results pipeline carries ${length(local.result_warnings)} finding(s) that affect what a stored result means: ${join("; ", [for f in local.result_warnings : "${f.code} ${f.message}"])}"
  }
}

# Reported rather than refused: an adopted bucket is somebody else's, and the
# hardening above was deliberately not applied to it.
check "adopted_bucket_is_not_configured_here" {
  assert {
    condition     = local.manage_results_bucket
    error_message = "run_artifact_bucket_name is set, so ${local.results_bucket_name} is adopted rather than created. None of the encryption, versioning or lifecycle rules in this configuration apply to it - in particular nothing will abort the incomplete multipart uploads a reclaimed worker leaves behind, and nothing will expire the query output this workgroup writes into it."
  }
}
