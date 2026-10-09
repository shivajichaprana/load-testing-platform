# ---------------------------------------------------------------------------
# Identity and tagging
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "Region the runner fleet is deployed into. The fleet should sit in the same region as the target unless the test is deliberately measuring inter-region latency, because otherwise every measurement carries a constant the report does not mention."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a region identifier such as us-east-1 or eu-west-2."
  }
}

variable "name_prefix" {
  description = "Prefix applied to every resource name this module creates."
  type        = string
  default     = "loadtest"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-20 characters, lowercase alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "tags" {
  description = "Tags merged onto every resource. A cost allocation tag is worth setting here: a fleet is the single most expensive thing in this account for the minutes it exists, and it is invisible in a monthly bill without one."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Network placement
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC the runner tasks are placed in."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8}([0-9a-f]{9})?$", var.vpc_id))
    error_message = "vpc_id must be a VPC identifier such as vpc-0123456789abcdef0."
  }
}

variable "runner_subnet_ids" {
  description = "Subnets the runner tasks are placed in. Each task consumes one address from one of these subnets for the duration of the run, so the usable address count is a ceiling on fleet size and is checked rather than assumed."
  type        = list(string)

  validation {
    condition     = length(var.runner_subnet_ids) > 0
    error_message = "runner_subnet_ids must contain at least one subnet."
  }

  validation {
    condition     = alltrue([for s in var.runner_subnet_ids : can(regex("^subnet-[0-9a-f]{8}([0-9a-f]{9})?$", s))])
    error_message = "Every entry in runner_subnet_ids must be a subnet identifier such as subnet-0123456789abcdef0."
  }

  validation {
    condition     = length(distinct(var.runner_subnet_ids)) == length(var.runner_subnet_ids)
    error_message = "runner_subnet_ids must not repeat a subnet; a repeated entry doubles that subnet's share of the fleet without doubling its address space."
  }
}

variable "runner_egress_mode" {
  description = <<-EOT
    How runner tasks reach the target, which is a measurement decision and not
    only a plumbing one.

      public_ip   Each task is given a public address in a public subnet. There
                  is no NAT charge, and the target sees as many distinct source
                  addresses as there are workers.

      private_nat Tasks sit in private subnets and leave through a NAT gateway.
                  The target sees one source address per gateway, and every byte
                  the fleet sends and receives is billed as NAT data processing.

    The difference is not a detail. Any per-source-address rate limit, WAF rule,
    or connection cap on the target path behaves differently against a fleet of
    separate addresses than against one shared address, so the two modes can
    produce different numbers for the same scenario at the same rate. Pick the
    one that matches how real traffic arrives, and record which was used.
  EOT
  type        = string
  default     = "public_ip"

  validation {
    condition     = contains(["public_ip", "private_nat"], var.runner_egress_mode)
    error_message = "runner_egress_mode must be public_ip or private_nat."
  }
}

variable "target_egress_rules" {
  description = "Destinations the runner security group may open connections to, as a list of objects with cidr, from_port, to_port and description. Egress is closed by default rather than opened to the world, because a generator with unrestricted egress is indistinguishable from one pointed at the wrong environment."
  type = list(object({
    cidr        = string
    from_port   = number
    to_port     = number
    description = string
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.target_egress_rules : can(cidrnetmask(r.cidr))])
    error_message = "Every target_egress_rules entry must carry a valid IPv4 CIDR."
  }

  validation {
    condition     = alltrue([for r in var.target_egress_rules : r.from_port >= 1 && r.to_port <= 65535 && r.from_port <= r.to_port])
    error_message = "Every target_egress_rules entry must carry a port range within 1-65535 with from_port no greater than to_port."
  }

  validation {
    condition     = alltrue([for r in var.target_egress_rules : length(trimspace(r.description)) > 0])
    error_message = "Every target_egress_rules entry must carry a description; an unexplained egress rule outlives the reason it was added."
  }
}

# ---------------------------------------------------------------------------
# The load objective
#
# These are the inputs the fleet size is derived from. They are deliberately
# stated as an objective rather than as a worker count, because a worker count
# written by hand is a guess that stops being right the moment the scenario,
# the image, or the target's latency changes.
# ---------------------------------------------------------------------------

variable "load_model" {
  description = <<-EOT
    Which quantity the test holds fixed.

      open    Arrivals are generated at a fixed rate regardless of how the
              target responds. Throughput is an input; degradation shows up as
              rising concurrency at the generator.

      closed  A fixed population of virtual users each waits for its response
              before issuing the next request. Throughput is an OUTPUT, equal
              to the population divided by the sum of response time and think
              time, so it falls as the target slows down.

    The consequence of the closed model is the one that catches people: a closed
    test cannot hold a target rate through a degradation, because the
    degradation is what reduces the rate. If the question is "what happens at N
    requests per second", the model has to be open; the closed model answers
    "what happens to N concurrent users", which is a different question with a
    different answer.
  EOT
  type        = string
  default     = "open"

  validation {
    condition     = contains(["open", "closed"], var.load_model)
    error_message = "load_model must be open or closed."
  }
}

variable "target_arrival_rate" {
  description = "Requests per second the fleet offers, for the open model. Ignored when load_model is closed."
  type        = number
  default     = 0

  validation {
    condition     = var.target_arrival_rate >= 0
    error_message = "target_arrival_rate must not be negative."
  }
}

variable "target_virtual_users" {
  description = "Size of the virtual user population, for the closed model. Ignored when load_model is open."
  type        = number
  default     = 0

  validation {
    condition     = var.target_virtual_users >= 0 && floor(var.target_virtual_users) == var.target_virtual_users
    error_message = "target_virtual_users must be a non-negative whole number."
  }
}

variable "latency_ceiling_ms" {
  description = <<-EOT
    The highest response time the run is expected to still be MEASURING rather
    than abandoning, in milliseconds.

    This is the sizing input people get wrong, and it is wrong in the direction
    that fails during the interesting part of the run. Concurrency at the
    generator is arrival rate multiplied by response time, so a fleet sized on
    the latency the target shows when it is healthy has exactly enough sockets
    for the healthy case and runs out as soon as the target slows down. The
    fleet then stops offering the target rate, and the resulting graph looks
    like the target recovering.

    Size on the latency ceiling you are willing to observe, not the latency you
    expect.
  EOT
  type        = number
  default     = 2000

  validation {
    condition     = var.latency_ceiling_ms > 0
    error_message = "latency_ceiling_ms must be greater than zero."
  }
}

variable "connection_reuse" {
  description = <<-EOT
    Whether the scenario reuses connections across requests, which moves the
    per-worker ceiling by roughly two orders of magnitude and is therefore a
    fleet sizing input rather than a scenario preference.

    With reuse, a worker holds one socket per in-flight request, so its ceiling
    is its concurrency. Without reuse, every completed request leaves its
    four-tuple unusable for the socket lingering interval, so the ceiling is a
    RATE: roughly the usable port count divided by that interval, which is a few
    hundred requests per second per worker against a single destination
    endpoint, far below anything the vCPU allocation would suggest.
  EOT
  type        = bool
  default     = true
}

variable "destination_endpoint_count" {
  description = <<-EOT
    How many distinct destination address-and-port pairs the scenario's targets
    resolve to.

    A connection is identified by source address, source port, destination
    address and destination port, so the usable port range is a per-DESTINATION
    budget and not a per-worker one. A fleet pointed at a single address has one
    budget; the same fleet pointed at a name that resolves to several addresses
    has that many. Two runs of one scenario against one service can therefore
    hit the socket ceiling at very different rates, with nothing in the scenario
    changed, purely because the name resolved differently.

    Set this to the number of addresses actually in rotation, and set it to 1
    when that is unknown, because 1 is the conservative answer.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.destination_endpoint_count >= 1 && floor(var.destination_endpoint_count) == var.destination_endpoint_count
    error_message = "destination_endpoint_count must be a whole number of at least 1."
  }
}

variable "worker_ephemeral_port_count" {
  description = "Size of the ephemeral port range available inside a runner task. The default is the size of the usual Linux default range, 32768 through 60999 inclusive. Widening the range in the image raises the ceiling and this value must then be raised to match, or the sizing will be conservative without saying so."
  type        = number
  default     = 28232

  validation {
    condition     = var.worker_ephemeral_port_count >= 1024 && var.worker_ephemeral_port_count <= 64511
    error_message = "worker_ephemeral_port_count must be between 1024 and 64511; the upper bound is the largest range that can start above the well-known and registered ports."
  }
}

variable "socket_linger_seconds" {
  description = "How long a closed connection's four-tuple stays unusable, in seconds. The default is the fixed interval a Linux socket spends waiting out any delayed duplicates after an active close. It is not tunable through a socket option, which is why the only real remedy for a rate ceiling caused by it is connection reuse."
  type        = number
  default     = 60

  validation {
    condition     = var.socket_linger_seconds > 0
    error_message = "socket_linger_seconds must be greater than zero."
  }
}

variable "requests_per_second_per_vcpu" {
  description = "Sustainable request rate one vCPU of the runner image can generate, measured rather than assumed. This is a property of the image and the scenario shape together: a scenario that parses a large response body or signs each request can be an order of magnitude below one that does neither, so a figure carried over from another image is not evidence."
  type        = number
  default     = 1500

  validation {
    condition     = var.requests_per_second_per_vcpu > 0
    error_message = "requests_per_second_per_vcpu must be greater than zero."
  }
}

variable "virtual_users_per_vcpu" {
  description = "Virtual users one vCPU of the runner image can hold open, for the closed model. Bounded in practice by per-user memory and by the generator's scheduler rather than by raw processor time."
  type        = number
  default     = 2500

  validation {
    condition     = var.virtual_users_per_vcpu > 0
    error_message = "virtual_users_per_vcpu must be greater than zero."
  }
}

variable "max_workers" {
  description = "Hard ceiling on derived fleet size. A guard against a mistyped objective turning into a bill: the derived count is refused rather than clamped, because a silently clamped fleet offers less load than the run reports."
  type        = number
  default     = 50

  validation {
    condition     = var.max_workers >= 1 && var.max_workers <= 1000 && floor(var.max_workers) == var.max_workers
    error_message = "max_workers must be a whole number between 1 and 1000."
  }
}

# ---------------------------------------------------------------------------
# Runner task shape
# ---------------------------------------------------------------------------

variable "runner_image" {
  description = "Image the runner tasks execute, which must be pinned by digest. A floating tag means two runs of the same committed scenario can execute different generator code, which makes every comparison between them unsound while leaving nothing in either result that says so."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._:/-]+@sha256:[0-9a-f]{64}$", var.runner_image))
    error_message = "runner_image must be pinned by digest, in the form registry/repository@sha256:<64 hex characters>."
  }
}

variable "runner_image_repository_arn" {
  description = "ARN of the registry repository runner_image is pulled from, used to scope the pull permission on the execution role. Leave null for a public registry, where there is nothing to scope."
  type        = string
  default     = null

  validation {
    condition     = var.runner_image_repository_arn == null || can(regex("^arn:aws[a-z-]*:ecr:[a-z0-9-]+:[0-9]{12}:repository/.+$", var.runner_image_repository_arn))
    error_message = "runner_image_repository_arn must be a registry repository ARN, or null."
  }
}

variable "runner_cpu" {
  description = "CPU units for one runner task. Valid values are fixed by the platform; the companion memory value is constrained by the one chosen here and is checked where both are known."
  type        = number
  default     = 2048

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384, 32768], var.runner_cpu)
    error_message = "runner_cpu must be one of 256, 512, 1024, 2048, 4096, 8192, 16384, 32768."
  }
}

variable "runner_memory" {
  description = "Memory in MiB for one runner task. Must be one of the values the chosen runner_cpu permits."
  type        = number
  default     = 4096

  validation {
    condition     = var.runner_memory >= 512 && floor(var.runner_memory) == var.runner_memory
    error_message = "runner_memory must be a whole number of at least 512 MiB."
  }
}

variable "runner_ephemeral_storage_gib" {
  description = "Task storage in GiB, or null for the platform default. Raise it only when the scenario stages large request bodies: results are streamed out during the run rather than written here, precisely so that the fleet does not depend on storage that disappears when a task stops."
  type        = number
  default     = null

  validation {
    condition     = var.runner_ephemeral_storage_gib == null || (var.runner_ephemeral_storage_gib >= 21 && var.runner_ephemeral_storage_gib <= 200)
    error_message = "runner_ephemeral_storage_gib must be between 21 and 200, or null for the platform default."
  }
}

variable "runner_stop_timeout_seconds" {
  description = <<-EOT
    Grace period between the stop signal and the kill signal.

    The platform caps this at 120 seconds, and a reclaimed interruptible task is
    warned exactly 120 seconds before it stops. Those two numbers being equal is
    the whole point: a timeout set to the maximum consumes the entire warning,
    so there is no margin for the signal to arrive and for a flush to finish.
    That is why results are streamed out during the run instead of written at
    the end, and why this value is below the cap rather than at it.
  EOT
  type        = number
  default     = 110

  validation {
    condition     = var.runner_stop_timeout_seconds >= 2 && var.runner_stop_timeout_seconds <= 120 && floor(var.runner_stop_timeout_seconds) == var.runner_stop_timeout_seconds
    error_message = "runner_stop_timeout_seconds must be a whole number between 2 and 120; the platform rejects anything outside that range."
  }
}

variable "log_retention_in_days" {
  description = "Retention on the runner log group. Runner logs are the record of what the fleet did, as distinct from what the target did, and they are the only place a worker that never reached its start instant leaves a trace."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_in_days)
    error_message = "log_retention_in_days must be one of the retention periods the log service accepts."
  }
}

# ---------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------

variable "capacity_on_demand_weight" {
  description = "Relative share of the fleet placed on uninterruptible capacity."
  type        = number
  default     = 1

  validation {
    condition     = var.capacity_on_demand_weight >= 0 && floor(var.capacity_on_demand_weight) == var.capacity_on_demand_weight
    error_message = "capacity_on_demand_weight must be a non-negative whole number."
  }
}

variable "capacity_spot_weight" {
  description = <<-EOT
    Relative share of the fleet placed on interruptible capacity.

    Cheap, and wrong for any run whose numbers will be compared against another
    run. A reclaimed worker removes its share of the offered load mid-run, so
    the measured throughput falls; nothing in the target's metrics distinguishes
    that from the target itself degrading, and the result reads as a regression
    in the system under test.

    Interruptible capacity is appropriate for exploratory and smoke runs, where
    the question is whether the scenario works at all. It is not appropriate for
    a run that establishes or is checked against a baseline. The weight is left
    adjustable and the choice is recorded with the run rather than being
    forbidden outright.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.capacity_spot_weight >= 0 && floor(var.capacity_spot_weight) == var.capacity_spot_weight
    error_message = "capacity_spot_weight must be a non-negative whole number."
  }
}

variable "capacity_on_demand_base" {
  description = "Number of workers placed on uninterruptible capacity before the weights apply at all. Only one provider in a strategy may carry a base, so this is the only base this module sets."
  type        = number
  default     = 0

  validation {
    condition     = var.capacity_on_demand_base >= 0 && floor(var.capacity_on_demand_base) == var.capacity_on_demand_base
    error_message = "capacity_on_demand_base must be a non-negative whole number."
  }
}

variable "account_fargate_vcpu_quota" {
  description = "The account's serverless vCPU quota in this region, which the derived fleet is checked against. Set it from the account's own limit rather than the documented default: it is adjustable, commonly adjusted, and a fleet that exceeds it fails partway through launching with placement failures rather than refusing up front."
  type        = number
  default     = 6

  validation {
    condition     = var.account_fargate_vcpu_quota > 0
    error_message = "account_fargate_vcpu_quota must be greater than zero."
  }
}

# ---------------------------------------------------------------------------
# Run coordination
# ---------------------------------------------------------------------------

variable "start_delay_seconds" {
  description = <<-EOT
    How long after launch the synchronized start instant is set, in seconds.

    Workers do not begin generating load when their container starts. Task start
    time is tens of seconds and varies between workers by more than the ramp
    this fleet is trying to describe, so a fleet that starts on container start
    produces a ramp smeared across its own scheduling noise and attributes it to
    the profile. Instead every worker is given one wall-clock instant and waits
    for it.

    The value has to exceed the slowest worker's time to reach a ready state,
    which is dominated by the image pull. A worker that is still starting when
    the instant passes has missed part of the run, and that is reported rather
    than absorbed, because the offered load was below target for as long as it
    was absent.
  EOT
  type        = number
  default     = 120

  validation {
    condition     = var.start_delay_seconds >= 30 && var.start_delay_seconds <= 900 && floor(var.start_delay_seconds) == var.start_delay_seconds
    error_message = "start_delay_seconds must be a whole number between 30 and 900; below 30 the slowest worker will routinely miss the start instant."
  }
}

# ---------------------------------------------------------------------------
# Runner task limits
# ---------------------------------------------------------------------------

variable "runner_nofile_limit" {
  description = <<-EOT
    Open file descriptors one runner task may hold, soft and hard.

    This platform already overrides the operating system default here, and the
    value it chooses is high enough that on a single-destination test the
    four-tuple budget is reached first. That is the opposite of a self-managed
    host, where the default of a thousand or so binds long before the port
    range does, and it is why this is not the usual place to look.

    It becomes the binding bound as soon as the scenario reaches enough
    destination addresses, because the four-tuple budget grows with that count
    while the descriptor limit does not. At the default port range the crossover
    is at three destination addresses. A socket that cannot be given a
    descriptor is not a slower socket; it is a failed connection the run records
    as a target error.
  EOT
  type        = number
  default     = 65535

  validation {
    condition     = var.runner_nofile_limit >= 1024 && floor(var.runner_nofile_limit) == var.runner_nofile_limit
    error_message = "runner_nofile_limit must be a whole number of at least 1024."
  }
}

variable "reserved_descriptors" {
  description = "Descriptors withheld from the socket budget for everything that is not a connection: the scenario files, the result stream, the log pipe, the runtime's own handles. Subtracted rather than ignored, because a budget computed to the last descriptor fails at the worst possible moment."
  type        = number
  default     = 256

  validation {
    condition     = var.reserved_descriptors >= 0 && floor(var.reserved_descriptors) == var.reserved_descriptors
    error_message = "reserved_descriptors must be a non-negative whole number."
  }
}

variable "platform_egress_cidrs" {
  description = <<-EOT
    Destinations the runner security group may reach on 443 for reasons that
    have nothing to do with the test: pulling the runner image, shipping logs,
    writing results.

    This rule cannot simply be omitted. The image is pulled over the task's own
    network interface, so a security group with no 443 egress produces a task
    that never starts, and the failure reads as a registry problem rather than
    as a firewall one.

    It is also the reason an egress allowlist aimed at the target is not an
    isolation boundary by itself: if this rule reaches the whole internet, as it
    does by default, it already admits any target on 443. Narrowing this to
    interface endpoints in a private subnet is what turns the target allowlist
    into something that actually constrains the fleet.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.platform_egress_cidrs) > 0
    error_message = "platform_egress_cidrs must contain at least one CIDR; with none, runner tasks cannot pull their image and will never start."
  }

  validation {
    condition     = alltrue([for c in var.platform_egress_cidrs : can(cidrnetmask(c))])
    error_message = "Every entry in platform_egress_cidrs must be a valid IPv4 CIDR."
  }
}

variable "container_insights" {
  description = "Cluster-level container metric collection. Worth its cost on a load fleet for one reason: the most common misreading of a run is attributing the GENERATOR's saturation to the target, and per-task processor and memory figures are what settle that argument."
  type        = string
  default     = "enabled"

  validation {
    condition     = contains(["enabled", "enhanced", "disabled"], var.container_insights)
    error_message = "container_insights must be enabled, enhanced or disabled."
  }
}

variable "run_artifact_bucket_name" {
  description = "Bucket the runners stream results into, or null. Results are written during the run rather than at the end, because a worker that is reclaimed or that fails at the far end of a long run would otherwise take the whole run's output with it."
  type        = string
  default     = null

  validation {
    condition     = var.run_artifact_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.run_artifact_bucket_name))
    error_message = "run_artifact_bucket_name must be a valid bucket name, or null."
  }
}

variable "metric_namespace" {
  description = "Metric namespace the runners publish into. The publish permission cannot be scoped to a resource, so it is scoped to this namespace by condition instead, which is the only boundary available on that action."
  type        = string
  default     = "LoadTesting/Runners"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]{1,255}$", var.metric_namespace)) && !startswith(var.metric_namespace, "AWS/")
    error_message = "metric_namespace must be 1-255 characters of letters, digits, dot, underscore, slash or hyphen, and must not begin with AWS/, which is reserved for service metrics."
  }
}

variable "runner_cpu_architecture" {
  description = <<-EOT
    Processor architecture the runner image is built for.

    This interacts with digest pinning in a way that is easy to get wrong.
    Pinning by digest is what makes two runs comparable, but a digest can refer
    either to a manifest LIST covering several architectures or to one
    architecture's image. A single-architecture digest set here against the
    other architecture produces a task that never starts, and the failure
    arrives as an image pull error rather than as an architecture mismatch.
    Pin the manifest list's digest, or keep the two values in step by hand.
  EOT
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.runner_cpu_architecture)
    error_message = "runner_cpu_architecture must be X86_64 or ARM64."
  }
}
