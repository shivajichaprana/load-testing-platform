data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Cluster and capacity
#
# The cluster is a container for the fleet's capacity strategy and its metrics,
# not a scheduler: nothing here maintains a desired count. Workers are launched
# per run and are expected to exit, because the exit status and the
# completeness of the results ARE the run's output.
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "runners" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }
}

resource "aws_ecs_cluster_capacity_providers" "runners" {
  cluster_name = aws_ecs_cluster.runners.name

  # Both providers are supplied by the platform and are named rather than
  # created. Listing the interruptible one does not place anything on it; the
  # weights below decide that.
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # This strategy is what a launch request uses when it does not carry one of
  # its own, which is how the fleet launcher keeps the capacity decision in the
  # configuration rather than in a command line.
  #
  # A weight omitted through the API is zero, and Terraform is the API. A
  # strategy whose weights are all zero is rejected when the fleet is launched
  # rather than when this is applied, so the total is refused up front instead.
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = var.capacity_on_demand_weight
    base              = var.capacity_on_demand_base
  }

  # Only one provider in a strategy may carry a base, so this one carries none.
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = var.capacity_spot_weight
  }
}

# Runner logs are the record of what the FLEET did, as distinct from what the
# target did, and they are the only place a worker that never reached its start
# instant leaves a trace. A worker that is absent from a run is otherwise
# indistinguishable from a worker that offered no load.
resource "aws_cloudwatch_log_group" "runners" {
  name              = "/aws/ecs/${var.name_prefix}-runner"
  retention_in_days = var.log_retention_in_days
}
