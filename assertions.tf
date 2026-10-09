# ---------------------------------------------------------------------------
# What the derived fleet implies, stated rather than left to be noticed.
#
# These are findings about the OBJECTIVE, not faults in the configuration. Each
# one describes something that changes what a run measures or what its numbers
# may be compared against, and each is reported with the figure it rests on so
# that it can be argued with.
# ---------------------------------------------------------------------------

locals {
  candidate_findings = [
    {
      code     = "L101"
      when     = local.derived_worker_count > 0 && local.worker_binding_constraint == "sockets"
      severity = "note"
      message  = format(
        "Each worker is bounded by its four-tuple budget at %.0f requests per second, below the %.0f the vCPU allocation would support. Giving a worker more vCPU will not shrink this fleet; reusing connections, or reaching more destination endpoints, will.",
        local.worker_rate_ceiling_sockets,
        local.worker_rate_ceiling_cpu,
      )
    },
    {
      code     = "L102"
      when     = local.derived_worker_count > 0 && !var.connection_reuse
      severity = "warning"
      message  = format(
        "Connection reuse is off, so each request holds a four-tuple for the response time plus the %ds lingering interval, capping a worker at %.0f requests per second. Turning reuse on raises that ceiling to %.0f for the same task shape.",
        var.socket_linger_seconds,
        local.worker_rate_ceiling_sockets,
        local.effective_tuple_budget / local.latency_ceiling_s,
      )
    },
    {
      code     = "L103"
      when     = local.derived_worker_count > 0 && var.destination_endpoint_count == 1
      severity = "note"
      message  = "The port budget is sized for a single destination endpoint, which is the conservative reading. If the target name resolves to several addresses the real ceiling is higher by that factor, and the fleet is correspondingly larger than it needs to be."
    },
    {
      code     = "L104"
      when     = local.interruptible_share > 0
      severity = "warning"
      message  = format(
        "About %.0f%% of the fleet is placed on interruptible capacity. A reclaimed worker withdraws its share of the offered load mid-run, which is indistinguishable in the target's metrics from the target degrading. Results from this configuration should not be compared against a baseline.",
        local.interruptible_share * 100,
      )
    },
    {
      code     = "L105"
      when     = var.runner_egress_mode == "private_nat"
      severity = "warning"
      message  = "Runners leave through a NAT gateway, so the target sees one source address per gateway and every byte the fleet sends and receives is billed as NAT data processing. Both matter: the first changes how a per-source rate limit behaves, the second makes a high-volume run cost more than the compute it ran on."
    },
    {
      code     = "L106"
      when     = var.runner_egress_mode == "public_ip" && local.derived_worker_count > 1
      severity = "note"
      message  = format(
        "The target will see up to %d distinct source addresses. A per-source-address rate limit on the target path therefore admits roughly that multiple of what it would admit from a single client, which is a property of this fleet's topology rather than of the service under test.",
        local.derived_worker_count,
      )
    },
    {
      code     = "L107"
      when     = local.run_task_batches > 1
      severity = "note"
      message  = format(
        "A launch request places at most %d tasks, so this fleet is launched in %d requests. Partial placement is the normal case: a successful response can carry placement failures alongside the tasks it did place, and the launcher must reconcile the count rather than trust it.",
        local.run_task_max_count,
        local.run_task_batches,
      )
    },
    {
      code     = "L108"
      when     = var.load_model == "closed" && var.target_arrival_rate > 0
      severity = "warning"
      message  = "An arrival rate is set while the closed model is selected, and it is ignored. Under the closed model throughput is an output, so the run cannot hold that rate through a degradation; the rate it achieves will be the population divided by the response time it observes."
    },
    {
      code     = "L109"
      when     = local.derived_worker_count > 0 && local.fleet_vcpu > var.account_fargate_vcpu_quota * 0.75
      severity = "warning"
      message  = format(
        "The fleet claims %.2f of the %.0f vCPU quota stated for this account, leaving little room for anything else running in it. A fleet that exceeds the quota does not refuse to launch; it places some workers and reports placement failures for the rest, and the run then offers less load than it claims to.",
        local.fleet_vcpu,
        var.account_fargate_vcpu_quota,
      )
    },
    {
      code     = "L110"
      when     = var.runner_stop_timeout_seconds >= 120
      severity = "warning"
      message  = "The stop timeout is at the platform cap, which is the same length as the warning an interrupted task receives. A flush that only begins when the stop signal arrives therefore has no margin at all, and the last of the run's results are the ones lost."
    },
    {
      code     = "L111"
      when     = local.tuple_budget_source == "descriptors"
      severity = "warning"
      message = format(
        "The socket budget is bounded by the descriptor limit at %d, not by the %d four-tuples the port range and destination count allow. Reaching more destination addresses will not raise it; only runner_nofile_limit will. A socket that cannot be given a descriptor is a failed connection, and the run records it against the target.",
        local.descriptor_budget_per_worker,
        local.port_budget_per_worker,
      )
    },
    {
      code     = "L112"
      when     = length(var.target_egress_rules) > 0 && contains(var.platform_egress_cidrs, "0.0.0.0/0")
      severity = "warning"
      message  = "The egress allowlist for the target is not an isolation boundary while platform_egress_cidrs reaches the whole internet, because that rule already admits any target on 443. Narrow it to interface endpoints in a private subnet, or read the target rules as documentation rather than as a constraint."
    },
  ]

  sizing_findings = [
    for f in local.candidate_findings : {
      code     = f.code
      severity = f.severity
      message  = f.message
    } if f.when
  ]

  sizing_warnings = [for f in local.sizing_findings : f if f.severity == "warning"]
}

# ---------------------------------------------------------------------------
# Assertions
#
# Hosted on a resource that contacts nothing, so every guard below is evaluated
# before anything is created. The arithmetic itself can also be inspected with
# no state at all through `terraform console`.
# These are refusals rather than advice: each one describes a configuration that
# would deploy cleanly and then produce a run whose numbers are wrong in a way
# the run itself does not report.
# ---------------------------------------------------------------------------

resource "terraform_data" "fleet_preconditions" {
  input = {
    workers = local.derived_worker_count
    model   = var.load_model
  }

  lifecycle {
    precondition {
      condition     = local.derived_worker_count > 0
      error_message = "The load objective is empty: set target_arrival_rate for the open model, or target_virtual_users for the closed one. A fleet of no workers applies cleanly and offers nothing."
    }

    precondition {
      condition     = local.derived_worker_count <= var.max_workers
      error_message = "The objective derives ${local.derived_worker_count} workers, above the max_workers ceiling of ${var.max_workers}. Raise the ceiling deliberately or lower the objective; the count is refused rather than clamped, because a clamped fleet offers less load than the run reports."
    }

    precondition {
      condition     = local.capacity_weight_total > 0
      error_message = "capacity_on_demand_weight and capacity_spot_weight are both zero. A weight omitted through the API is zero, and a strategy whose weights are all zero is rejected when the fleet is launched rather than when it is applied, so it is refused here instead."
    }

    precondition {
      condition     = var.capacity_on_demand_base <= local.derived_worker_count
      error_message = "capacity_on_demand_base of ${var.capacity_on_demand_base} exceeds the derived fleet size of ${local.derived_worker_count}, so the weights would never apply and the whole fleet would be placed on uninterruptible capacity regardless of them."
    }

    precondition {
      condition     = local.longest_name_length <= local.name_budget
      error_message = "name_prefix is too long: the longest name this module creates would be ${local.longest_name_length} characters against a ${local.name_budget}-character ceiling imposed by the role names."
    }

    precondition {
      condition     = var.load_model == "open" || var.virtual_users_per_vcpu > 0
      error_message = "The closed model requires virtual_users_per_vcpu to size the fleet."
    }
  }
}

# Advisory assertions. These surface the findings above in plan output, where a
# reader is looking, instead of only in an output a reader has to ask for.
check "fleet_has_no_warnings" {
  assert {
    condition     = length(local.sizing_warnings) == 0
    error_message = "The load objective carries ${length(local.sizing_warnings)} finding(s) that affect what this run measures: ${join("; ", [for f in local.sizing_warnings : "${f.code} ${f.message}"])}"
  }
}

check "fleet_fits_stated_quota" {
  assert {
    condition     = local.fleet_vcpu <= var.account_fargate_vcpu_quota
    error_message = "The derived fleet needs ${local.fleet_vcpu} vCPU against a stated quota of ${var.account_fargate_vcpu_quota}. Raise the quota before launching, or reduce the objective: the shortfall appears as placement failures partway through the launch, not as a refusal."
  }
}
