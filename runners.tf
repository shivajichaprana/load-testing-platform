data "aws_subnet" "runner" {
  for_each = toset(var.runner_subnet_ids)
  id       = each.value
}

data "aws_route_table" "runner" {
  for_each  = toset(var.runner_subnet_ids)
  subnet_id = each.value
}

locals {
  # Addresses the fleet can draw on. Each task holds one for the duration of the
  # run, so this is a ceiling on fleet size rather than a preference.
  #
  # Read at plan time, which bounds what it can prove: anything else in these
  # subnets may take an address between the plan and the launch. It is a sound
  # proof that a fleet does NOT fit and weak evidence that one does.
  available_addresses = sum([for s in data.aws_subnet.runner : s.available_ip_address_count])

  # A default route through an internet gateway is the only thing that makes a
  # public address usable. There is no alternative topology that does, so this
  # is checked as a refusal.
  subnet_reaches_internet_gateway = {
    for id, rt in data.aws_route_table.runner : id => anytrue([
      for r in rt.routes : r.cidr_block == "0.0.0.0/0" && startswith(try(r.gateway_id, ""), "igw-")
    ])
  }

  # A default route through a NAT gateway is the USUAL private path but not the
  # only one, so its absence is reported rather than refused: a transit gateway
  # or an interface-endpoint-only subnet is a legitimate configuration this
  # cannot see.
  subnet_reaches_nat_gateway = {
    for id, rt in data.aws_route_table.runner : id => anytrue([
      for r in rt.routes : r.cidr_block == "0.0.0.0/0" && startswith(try(r.nat_gateway_id, ""), "nat-")
    ])
  }

  assign_public_ip = var.runner_egress_mode == "public_ip"
}

# ---------------------------------------------------------------------------
# Runner security group
#
# No ingress at all: a load generator is a client. Egress is opened explicitly
# in two parts, because the two parts mean different things - see the note on
# platform_egress_cidrs for why the target allowlist constrains nothing while
# the platform rule is open to the internet.
# ---------------------------------------------------------------------------

resource "aws_security_group" "runner" {
  name        = "${var.name_prefix}-runner"
  description = "Load generator workers. Client-only: no ingress, explicit egress."
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-runner" }

  lifecycle {
    create_before_destroy = true
  }
}

# Rules are separate resources rather than inline blocks. An inline egress block
# and anything that manages rules outside it fight over the same state on every
# plan, and the fight is silent until a rule disappears mid-run.
resource "aws_vpc_security_group_egress_rule" "platform" {
  for_each = toset(var.platform_egress_cidrs)

  security_group_id = aws_security_group.runner.id
  description       = "Image pull, log delivery and result upload"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "target" {
  for_each = {
    for r in var.target_egress_rules : "${r.cidr}-${r.from_port}-${r.to_port}" => r
  }

  security_group_id = aws_security_group.runner.id
  description       = each.value.description
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  ip_protocol       = "tcp"
}

# ---------------------------------------------------------------------------
# Runner task definition
#
# Nothing here carries a value that belongs to one run. The run identifier, the
# synchronized start instant, the per-worker share of the rate and the worker's
# index are supplied as overrides at launch, so that two runs of one scenario
# differ in their launch request and not in their task definition - which is
# what lets the definition's revision be part of a result's provenance.
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "runner" {
  family                   = "${var.name_prefix}-runner"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.runner_cpu
  memory                   = var.runner_memory
  execution_role_arn       = aws_iam_role.runner_execution.arn
  task_role_arn            = aws_iam_role.runner_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.runner_cpu_architecture
  }

  dynamic "ephemeral_storage" {
    for_each = var.runner_ephemeral_storage_gib == null ? [] : [var.runner_ephemeral_storage_gib]

    content {
      size_in_gib = ephemeral_storage.value
    }
  }

  # The root filesystem is read-only, so the scratch area is an explicit
  # volume. There is no tmpfs on this launch type, which is why this is a
  # task-managed volume rather than a memory-backed mount.
  volume {
    name = "scratch"
  }

  container_definitions = jsonencode([
    {
      name      = "runner"
      image     = var.runner_image
      essential = true

      # Below the platform cap on purpose. The cap is the same length as the
      # warning an interrupted task receives, so a timeout set to it leaves no
      # margin for the signal to arrive and a flush to finish.
      stopTimeout = var.runner_stop_timeout_seconds

      readonlyRootFilesystem = true

      mountPoints = [
        {
          sourceVolume  = "scratch"
          containerPath = "/tmp"
          readOnly      = false
        },
      ]

      # An init process so that the stop signal reaches the generator rather
      # than only its shell, and so that a scenario spawning helpers does not
      # accumulate unreaped children for the length of the run.
      linuxParameters = {
        initProcessEnabled = true
      }

      # The platform raises this well above the operating system default, and
      # the figure matters: it is one of the two bounds on how many connections
      # a worker can hold. It is set explicitly so that the number the sizing
      # arithmetic used is the number the container gets.
      ulimits = [
        {
          name      = "nofile"
          softLimit = var.runner_nofile_limit
          hardLimit = var.runner_nofile_limit
        },
      ]

      environment = [
        { name = "RUNNER_METRIC_NAMESPACE", value = var.metric_namespace },
        { name = "RUNNER_PARAMETER_PREFIX", value = "/${var.name_prefix}/run" },
        { name = "RUNNER_ARTIFACT_BUCKET", value = coalesce(var.run_artifact_bucket_name, "") },
        { name = "RUNNER_ARTIFACT_PREFIX", value = "${var.name_prefix}/runs" },
        { name = "RUNNER_LOAD_MODEL", value = var.load_model },
        { name = "RUNNER_CONNECTION_REUSE", value = tostring(var.connection_reuse) },
        { name = "RUNNER_STOP_TIMEOUT_SECONDS", value = tostring(var.runner_stop_timeout_seconds) },
      ]

      # No health check. A load generator has no steady state to probe, and a
      # failing probe would stop the task: the container would be killed for
      # being slow at exactly the point in the run where slowness is the
      # measurement.
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.runners.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "runner"
        }
      }
    },
  ])

  lifecycle {
    precondition {
      condition     = local.derived_worker_count <= local.available_addresses
      error_message = "The objective derives ${local.derived_worker_count} workers and the chosen subnets have ${local.available_addresses} free address(es) between them. Each task holds one address for the whole run, so the shortfall appears as placement failures partway through the launch rather than as a refusal."
    }

    precondition {
      condition     = !local.assign_public_ip || alltrue([for ok in local.subnet_reaches_internet_gateway : ok])
      error_message = "runner_egress_mode is public_ip, but not every runner subnet has a default route to an internet gateway. A public address with no such route cannot reach anything, so the tasks will fail to pull their image and the error will name the registry rather than the route table."
    }

    precondition {
      condition     = contains(local.valid_memory_for_runner_cpu, var.runner_memory)
      error_message = "runner_memory ${var.runner_memory} MiB is not permitted with runner_cpu ${var.runner_cpu}; the platform rejects the pair at registration. Permitted with this CPU value: ${join(", ", [for m in local.valid_memory_for_runner_cpu : tostring(m)])}."
    }
  }
}

# Reported rather than refused: a private subnet may legitimately reach the
# internet through something this configuration cannot see, or may deliberately
# reach nothing but interface endpoints.
check "private_subnets_have_an_egress_path" {
  assert {
    condition     = local.assign_public_ip || alltrue([for ok in local.subnet_reaches_nat_gateway : ok])
    error_message = "runner_egress_mode is private_nat and at least one runner subnet has no default route to a NAT gateway. If egress is provided another way, or deliberately only through interface endpoints, this is expected; otherwise the tasks will not start."
  }
}
