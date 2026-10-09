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
