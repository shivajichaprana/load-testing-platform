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
