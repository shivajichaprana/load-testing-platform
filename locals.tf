# ---------------------------------------------------------------------------
# Naming and tagging
# ---------------------------------------------------------------------------

locals {
  # Every name this module creates is the prefix plus one of these suffixes.
  # The list exists so that the name budget below is derived from the names
  # that are actually created rather than from a figure written once and left
  # to drift when a resource is added.
  name_suffixes = [
    "-cluster",
    "-runner",
    "-runner-execution",
    "-runner-task",
  ]

  longest_name_suffix = max([for s in local.name_suffixes : length(s)]...)

  # The narrowest limit any of these names meets is the 64-character ceiling on
  # a role name; the cluster name, the task definition family and the security
  # group name are all bounded far above that. name_prefix is independently
  # capped at 20 characters, so this budget cannot currently be exceeded. It is
  # asserted anyway, for the edit that adds a longer suffix.
  name_budget         = 64
  longest_name_length = length(var.name_prefix) + local.longest_name_suffix

  tags = merge(
    {
      Component = "load-generation"
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

# ---------------------------------------------------------------------------
# Fleet sizing
#
# The fleet size is derived from the load objective rather than written down,
# and every bound that contributes to it is published as an output so that a
# number nobody can explain is not what the run is launched with.
#
# Three bounds apply to one worker:
#
#   sockets  A connection is identified by its source address, source port,
#            destination address and destination port. The usable ephemeral
#            port range is therefore a budget per DESTINATION endpoint, and a
#            worker's share of the offered rate is bounded by how long each
#            request occupies one of those four-tuples.
#
#   cpu      A measured property of the runner image and the scenario shape.
#
#   memory   Only indirectly, through the virtual user population a worker can
#            hold open in the closed model.
#
# The socket bound is the one that surprises people, because it is usually far
# below what the vCPU allocation suggests and it depends on a scenario
# property - connection reuse - that reads like an implementation detail.
# ---------------------------------------------------------------------------

locals {
  task_vcpu         = var.runner_cpu / 1024
  latency_ceiling_s = var.latency_ceiling_ms / 1000

  # Four-tuples one worker may hold at once.
  port_budget_per_worker = var.worker_ephemeral_port_count * var.destination_endpoint_count

  # How long one request occupies a four-tuple.
  #
  # With reuse the socket is handed to the next request as soon as the response
  # is read, so the occupancy is the response time. Without reuse the tuple is
  # additionally unusable for the socket lingering interval after the close.
  #
  # Connection reuse removes exactly one term from this denominator, and because
  # the lingering interval is typically one to two orders of magnitude larger
  # than the latency ceiling, that single term accounts for the whole
  # difference between the two ceilings. It is not a tuning detail.
  tuple_occupancy_s = var.connection_reuse ? local.latency_ceiling_s : local.latency_ceiling_s + var.socket_linger_seconds

  # Per-worker rate ceilings, in requests per second.
  worker_rate_ceiling_sockets = local.port_budget_per_worker / local.tuple_occupancy_s
  worker_rate_ceiling_cpu     = var.requests_per_second_per_vcpu * local.task_vcpu
  worker_rate_ceiling         = min(local.worker_rate_ceiling_sockets, local.worker_rate_ceiling_cpu)

  # Which of the two bounds is binding. Worth reporting rather than inferring:
  # a fleet whose workers are socket-bound gets smaller if the scenario starts
  # reusing connections, and no larger at all if the task is given more vCPU.
  worker_binding_constraint = local.worker_rate_ceiling_sockets <= local.worker_rate_ceiling_cpu ? "sockets" : "cpu"

  # Open model: concurrency the objective implies at the latency ceiling.
  required_concurrency = var.target_arrival_rate * local.latency_ceiling_s

  workers_for_open_model = var.target_arrival_rate <= 0 ? 0 : ceil(var.target_arrival_rate / local.worker_rate_ceiling)

  # Closed model: the population's implied rate is highest when think time is
  # zero, which is the case this has to be sized for. The population itself is
  # separately bounded by what one worker can hold open.
  implied_rate_closed_model = var.target_virtual_users / local.latency_ceiling_s
  worker_vu_ceiling_cpu     = var.virtual_users_per_vcpu * local.task_vcpu

  workers_for_closed_model = var.target_virtual_users <= 0 ? 0 : max(
    ceil(var.target_virtual_users / local.worker_vu_ceiling_cpu),
    ceil(local.implied_rate_closed_model / local.worker_rate_ceiling_sockets),
  )

  derived_worker_count = var.load_model == "open" ? local.workers_for_open_model : local.workers_for_closed_model

  # What the derived fleet consumes.
  fleet_vcpu   = local.derived_worker_count * local.task_vcpu
  fleet_memory = local.derived_worker_count * var.runner_memory

  # A launch request places at most ten tasks, so a fleet above that size is
  # launched in several requests. Each one can return placement failures
  # alongside successes in the same successful response, which is why the
  # launcher treats a partially placed fleet as the normal case.
  run_task_max_count = 10
  run_task_batches   = ceil(local.derived_worker_count / local.run_task_max_count)

  # Capacity provider strategy. A weight left unset is zero through the API,
  # which Terraform is, and a strategy whose weights are all zero is rejected
  # at launch rather than at apply. The total is therefore checked.
  capacity_weight_total = var.capacity_on_demand_weight + var.capacity_spot_weight
  interruptible_share   = local.capacity_weight_total == 0 ? 0 : var.capacity_spot_weight / local.capacity_weight_total
}

# ---------------------------------------------------------------------------
# Valid task shapes
#
# The permitted memory values depend on the chosen CPU value, which a single
# variable validation block cannot express because it may only reference its
# own variable. The pairing is checked where both are in scope instead.
# ---------------------------------------------------------------------------

locals {
  # Keys are quoted because a bare integer is not a valid object key: an
  # unquoted key must be an identifier, and an identifier may not begin with a
  # digit. The lookup converts the CPU value to a string for the same reason.
  fargate_memory_for_cpu = {
    "256"   = [512, 1024, 2048]
    "512"   = [1024, 2048, 3072, 4096]
    "1024"  = range(2048, 8193, 1024)
    "2048"  = range(4096, 16385, 1024)
    "4096"  = range(8192, 30721, 1024)
    "8192"  = range(16384, 61441, 4096)
    "16384" = range(32768, 122881, 8192)
    "32768" = [61440, 122880, 249856]
  }

  valid_memory_for_runner_cpu = local.fargate_memory_for_cpu[tostring(var.runner_cpu)]
}
