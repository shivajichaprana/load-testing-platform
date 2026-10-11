# ---------------------------------------------------------------------------
# Sizing outputs
#
# These are evaluable with nothing deployed, which is the point: a fleet can be
# sized, argued about and rejected before any capacity is created. Every figure
# the fleet size rests on is published, because a worker count whose derivation
# is not inspectable is a number nobody can challenge.
# ---------------------------------------------------------------------------

output "fleet_plan" {
  description = "The derived fleet and what it consumes."
  value = {
    load_model          = var.load_model
    worker_count        = local.derived_worker_count
    worker_vcpu         = local.task_vcpu
    worker_memory_mib   = var.runner_memory
    fleet_vcpu          = local.fleet_vcpu
    fleet_memory_mib    = local.fleet_memory
    launch_requests     = local.run_task_batches
    interruptible_share = local.interruptible_share
    egress_mode         = var.runner_egress_mode
  }
}

output "fleet_bounds" {
  description = "The per-worker ceilings the fleet size was derived from, and which of them was binding."
  value = {
    binding_constraint         = local.worker_binding_constraint
    tuple_budget_per_worker    = local.port_budget_per_worker
    tuple_occupancy_seconds    = local.tuple_occupancy_s
    rate_ceiling_sockets_per_s = local.worker_rate_ceiling_sockets
    rate_ceiling_cpu_per_s     = local.worker_rate_ceiling_cpu
    rate_ceiling_per_worker    = local.worker_rate_ceiling
    required_concurrency       = local.required_concurrency
    virtual_user_ceiling_cpu   = local.worker_vu_ceiling_cpu
    implied_rate_closed_model  = local.implied_rate_closed_model
  }
}

output "fleet_findings" {
  description = "Findings about the load objective: everything that changes what this run measures or what its numbers may be compared against."
  value       = local.sizing_findings
}

output "runner_naming" {
  description = "The names this module creates and the budget they are checked against."
  value = {
    prefix              = var.name_prefix
    suffixes            = local.name_suffixes
    longest_name_length = local.longest_name_length
    name_budget         = local.name_budget
  }
}

output "worker_socket_budget" {
  description = "Where one worker's socket budget comes from and how much headroom it leaves. Published separately from fleet_bounds because the two bounds have different remedies and neither helps with the other."
  value = {
    source                       = local.tuple_budget_source
    port_budget_per_worker       = local.port_budget_per_worker
    descriptor_budget_per_worker = local.descriptor_budget_per_worker
    effective_tuple_budget       = local.effective_tuple_budget
    concurrency_per_worker       = local.derived_worker_count == 0 ? 0 : local.required_concurrency / local.derived_worker_count
  }
}

# ---------------------------------------------------------------------------
# Deployed identifiers
#
# These are the values the fan-out launcher is given, so they are published as
# outputs rather than copied into a command by hand.
# ---------------------------------------------------------------------------

output "cluster_name" {
  description = "Cluster the fleet is launched into."
  value       = aws_ecs_cluster.runners.name
}

output "cluster_arn" {
  description = "Cluster ARN, for a launcher invoked from another account's pipeline."
  value       = aws_ecs_cluster.runners.arn
}

output "task_definition_arn" {
  description = "Runner task definition, revision included. The revision is part of a result's provenance: it is what says which generator code produced a number."
  value       = aws_ecs_task_definition.runner.arn
}

output "task_definition_revision" {
  description = "Revision of the runner task definition, pulled out separately so a result can record it without parsing an ARN."
  value       = aws_ecs_task_definition.runner.revision
}

output "runner_security_group_id" {
  description = "Security group the runner tasks are placed in."
  value       = aws_security_group.runner.id
}

output "runner_log_group_name" {
  description = "Log group carrying what the FLEET did, as distinct from what the target did."
  value       = aws_cloudwatch_log_group.runners.name
}

output "runner_role_arns" {
  description = "The two roles, kept separate: the platform's agent assumes one and the scenario assumes the other."
  value = {
    execution = aws_iam_role.runner_execution.arn
    task      = aws_iam_role.runner_task.arn
  }
}

output "runner_placement" {
  description = "Where the fleet is placed and what the subnets had free when this was planned. The address count is a sound proof that a fleet does not fit and weak evidence that one does, since anything else in these subnets may take an address before the launch."
  value = {
    subnet_ids              = var.runner_subnet_ids
    assign_public_ip        = local.assign_public_ip
    available_addresses     = local.available_addresses
    subnet_internet_gateway = local.subnet_reaches_internet_gateway
    subnet_nat_gateway      = local.subnet_reaches_nat_gateway
  }
}

# ---------------------------------------------------------------------------
# Results pipeline
#
# Published for the same reason the sizing figures are: a result is only
# comparable against another result when the two agree about how they were
# aggregated, and that agreement is checkable only if the terms are written
# down somewhere a reader can get at.
# ---------------------------------------------------------------------------

output "results_storage" {
  description = "Where results land, and the three retention lengths that follow from one figure."
  value = {
    bucket            = local.results_bucket_name
    managed_here      = local.manage_results_bucket
    samples_prefix    = local.samples_prefix
    index_prefix      = local.index_prefix
    query_results     = local.query_results_prefix
    sample_key        = local.sample_key_template
    index_key         = local.index_key_template
    queryable_days    = local.queryable_days
    expiry_days       = var.results_retention_days
    stored_total_days = local.storage_days
  }
}

output "result_catalog" {
  description = "The catalogue a query reads. run_samples is partitioned by date and by run identifier, and the run identifier is an injected projection: a query against it with no run filter FAILS rather than returning everything, which is why run_index exists and is partitioned by date alone."
  value = {
    database      = aws_glue_catalog_database.results.name
    samples_table = aws_glue_catalog_table.run_samples.name
    index_table   = aws_glue_catalog_table.run_index.name
    partitions = {
      (local.samples_table) = local.sample_partition_order
      (local.index_table)   = local.index_partition_order
    }
    workgroup      = aws_athena_workgroup.results.name
    scan_cutoff    = var.query_scan_cutoff_bytes
    named_queries  = sort([for name, q in aws_athena_named_query.catalog : q.name])
    unread_metrics = local.unqueried_metric_sources
  }
}

output "result_contract" {
  description = "What a worker is told about writing results: the key template, the flush interval, the shared bucket ladder and how metrics are published. Published as an output as well as a parameter because a parameter's value is sensitive in plan output whatever its type, and a change to the result schema is the change that most needs reading in a plan."
  value       = local.result_contract
}

output "result_contract_parameter" {
  description = "Parameter the workers read the contract from. The version is the second half of a result's provenance: the task definition's revision records which generator produced a number and this records how the number was aggregated. A worker records the version it actually read, because nothing stops the parameter changing between a launch and that read."
  value = {
    name    = aws_ssm_parameter.result_contract.name
    version = aws_ssm_parameter.result_contract.version
    bytes   = length(local.result_contract_json)
    budget  = local.contract_size_budget
  }
}

output "result_metrics" {
  description = "The metric catalogue, with the generator metric each one is published from. One definition feeds the contract the workers read, the dashboards' widgets and the guards over the committed SQL - because a dashboard naming a metric nothing publishes renders blank on a page that applied cleanly."
  value = {
    namespace  = var.metric_namespace
    publish    = var.metric_publish_mode
    resolution = var.metric_resolution_seconds
    dimensions = local.stable_dimensions
    phases     = local.phase_names
    latency    = local.latency_statistics
    metrics    = local.result_metrics
  }
}

output "result_findings" {
  description = "Findings about the pipeline: everything that changes what a stored result means or what it may be compared against."
  value       = local.result_findings
}

output "dashboards" {
  description = "The two dashboards, kept apart on purpose: one shows what the target did and one shows what the generator did, and the commonest misreading of a load test is attributing the second to the first."
  value = {
    enabled = local.dashboards_enabled
    period  = local.dashboard_period
    run     = local.dashboards_enabled ? aws_cloudwatch_dashboard.run[0].dashboard_name : null
    fleet   = local.dashboards_enabled ? aws_cloudwatch_dashboard.fleet[0].dashboard_name : null
  }
}
