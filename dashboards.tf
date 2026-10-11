# ---------------------------------------------------------------------------
# Dashboards
#
# Two of them, and the split is the point rather than tidiness.
#
#   The RUN dashboard shows what the target did: rates, errors, latency.
#   The FLEET dashboard shows what the generator did: processors, memory,
#   tasks, population, sockets.
#
# They are separate because the single most common misreading of a load test is
# attributing the GENERATOR's saturation to the target. Both effects look
# identical from the run dashboard alone - the rate stops rising and latency
# climbs - and the only thing that settles the argument is the second set of
# figures. Putting them on one page invites reading a correlation as a cause;
# putting them on two means the question has to be asked deliberately.
#
# Four properties of a CloudWatch dashboard decide what these can and cannot
# show, and all four are worth knowing before reading one:
#
#   A widget's period must be a multiple of 60 seconds, with 60 the minimum.
#   There is no sub-minute view. A 90-second smoke run is one or two points on
#   every graph here, which is not a reading of anything - short runs are read
#   from the query catalogue, not from this page.
#
#   periodOverride is set to inherit rather than auto. Under auto, widening the
#   dashboard's time range silently re-periods every graph, and a 95th
#   percentile over a five-minute period is a different quantity from one over
#   a minute while the widget still says p95.
#
#   liveData is on for the run widgets. Without it the most recent minute -
#   data published but not yet fully aggregated - is missing, and on a short
#   run that is a large fraction of the whole thing.
#
#   A dashboard is written before any run exists, so it cannot name a run. A
#   dimension combination IS a metric, so dimensioning by run identifier would
#   create a fresh custom metric per run, each billed for the calendar month
#   although it lived for minutes, and none of them chartable in advance. Run
#   attribution lives in the object store instead, where it costs a prefix.
#
# And one failure mode that has no mitigation other than not making the
# mistake: creating a dashboard SUCCEEDS when its body is merely warnable. The
# API returns validation messages, and if they are warnings the dashboard is
# created anyway with the note that some elements may not render. A widget
# naming a metric nothing publishes therefore applies cleanly and renders
# blank. That is why every metric name, dimension and namespace below is read
# out of the same catalogue the result contract and the publish permission are
# built from, rather than written here.
# ---------------------------------------------------------------------------

locals {
  dashboards_enabled = var.create_dashboards

  # A widget period must be a multiple of 60 with 60 as the minimum; this is
  # refused rather than rounded, because a rounded period changes what every
  # statistic on the page means.
  dashboard_period = var.dashboard_period_seconds

  # Flushes one period contains. WorkerFlushes is one datum per worker per
  # flush, so the number of workers reporting is the sum divided by this - and
  # the divisor is published on the page rather than folded into a label,
  # because it is the one figure that makes that count mean anything.
  flushes_per_period = local.dashboard_period / var.result_flush_seconds

  # The dimension names a widget's metric entry carries. Taken from the same
  # names the result contract publishes and the publish permission is scoped
  # by, because a widget whose dimension name does not match what the workers
  # send renders blank on a dashboard that applied cleanly.
  fleet_dim_name  = local.fleet_dimension_name
  fleet_dim_value = local.stable_dimensions[local.fleet_dimension_name]
  phase_dim_name  = local.phase_dimension_name

  # The judged phase. A latency percentile over a whole run includes the ramp,
  # during which the target is deliberately being given less than it will get.
  judged_phase = "steady"

  # Percentile statistics need values. From a statistic set they are
  # retrievable only in the degenerate case where every sample in the set is
  # identical, so a percentile widget over statistic-set data is permanently
  # empty rather than approximately right - which is the better failure, and
  # still a failure worth not shipping.
  latency_statistics = var.metric_publish_mode == "values" ? ["p50", "p90", "p95", "p99"] : ["Average", "Maximum"]

  # Container Insights supplies the generator's own processor and memory
  # figures. With collection disabled those metrics do not exist, and a widget
  # naming them renders blank on a dashboard that applied cleanly - so the
  # widgets are omitted instead and the omission is reported.
  fleet_metrics_available = var.container_insights != "disabled"

  dashboard_preamble = join("\n", [
    "## Target view - what the service under test did",
    "",
    "Period is **${local.dashboard_period}s**, the floor a dashboard widget allows (a multiple of 60, minimum 60). A run shorter than a few minutes is a handful of points here; read a short run from the query catalogue instead.",
    "",
    "Graphs are **not** scoped to a run - a dashboard is written before a run exists, so it cannot name one. When runs overlap, these figures are their sum. Per-run figures come from `run_samples`.",
    "",
    "Latency is scoped to the **${local.judged_phase}** phase and to responses the target meant to send. An error response is cheaper than a correct one, so an unscoped percentile improves as a service starts failing.",
    "",
    "A blank graph before the first run is a metric that has never been published, which looks the same as a run that offered no load. The fleet view is the second half of every reading on this page.",
  ])

  fleet_preamble = join("\n", [
    "## Generator view - what the fleet itself did",
    "",
    "This page exists to settle one question: was it the target or the load generator? A rate that stops rising and a latency that climbs look identical from the target view whichever it was.",
    "",
    "**Connections held** against the socket budget of **${local.effective_tuple_budget}** per worker is the first thing to check. A worker at its budget cannot open a socket, and the failed request is recorded against the target's name because that is what it was aimed at.",
    "",
    "**Population in use** against the pre-allocated population says whether the arrival rate was actually met. Under the open model a shortfall appears as dropped iterations; under the closed model the rate simply falls, which is the model's behaviour and not a finding.",
    "",
    local.fleet_metrics_available ? "Processor and memory figures come from cluster-level container metrics." : "Processor and memory figures are **absent**: container metric collection is disabled on this cluster, so those widgets are omitted rather than shipped blank.",
  ])
}

# ---------------------------------------------------------------------------
# Run dashboard
# ---------------------------------------------------------------------------

locals {
  run_widgets = concat(
    [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 5
        properties = {
          markdown = local.dashboard_preamble
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 5
        width  = 6
        height = 5
        properties = {
          title     = "Completed requests per second"
          view      = "singleValue"
          sparkline = true
          region    = var.aws_region
          period    = local.dashboard_period
          liveData  = true
          metrics = [
            [var.metric_namespace, "RequestsCompleted", local.fleet_dim_name, local.fleet_dim_value, { id = "m1", stat = "Sum", visible = false }],
            # PERIOD() rather than the configured period written out: the two
            # would then be separate figures, and changing the widget's period
            # would leave the arithmetic describing the old one.
            [{ expression = "m1/PERIOD(m1)", label = "completed/s", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 5
        width  = 6
        height = 5
        properties = {
          title     = "Error rate"
          view      = "singleValue"
          sparkline = true
          region    = var.aws_region
          period    = local.dashboard_period
          liveData  = true
          metrics = [
            [var.metric_namespace, "RequestsCompleted", local.fleet_dim_name, local.fleet_dim_value, { id = "m1", stat = "Sum", visible = false }],
            [var.metric_namespace, "RequestsFailed", local.fleet_dim_name, local.fleet_dim_value, { id = "m2", stat = "Sum", visible = false }],
            # A period with no requests produces no data point rather than a
            # zero, because there is no error rate when nothing was asked. That
            # is the honest reading and it is also what the arithmetic does on
            # its own, so nothing fills it.
            [{ expression = "100*(m2/(m1+m2))", label = "% failed", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 5
        width  = 6
        height = 5
        properties = {
          title     = "Iterations the generator dropped"
          view      = "singleValue"
          sparkline = true
          region    = var.aws_region
          period    = local.dashboard_period
          liveData  = true
          metrics = [
            [var.metric_namespace, "IterationsDropped", local.fleet_dim_name, local.fleet_dim_value, { id = "m1", stat = "Sum", label = "dropped" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 5
        width  = 6
        height = 5
        properties = {
          title     = "Workers reporting"
          view      = "singleValue"
          sparkline = true
          region    = var.aws_region
          period    = local.dashboard_period
          liveData  = true
          metrics = [
            [var.metric_namespace, "WorkerFlushes", local.fleet_dim_name, local.fleet_dim_value, { id = "m1", stat = "Sum", visible = false }],
            # One flush per worker per interval, so the worker count is the sum
            # divided by the flushes a period contains.
            [{ expression = "m1/${local.flushes_per_period}", label = "workers", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 10
        width  = 12
        height = 7
        properties = {
          title    = "Request rate by phase"
          view     = "timeSeries"
          stacked  = true
          region   = var.aws_region
          period   = local.dashboard_period
          liveData = true
          yAxis = {
            left = {
              label     = "requests/s"
              min       = 0
              showUnits = false
            }
          }
          metrics = concat(
            [
              for i, phase in local.phase_names :
              [var.metric_namespace, "RequestsCompleted", local.fleet_dim_name, local.fleet_dim_value, local.phase_dim_name, phase, { id = "m${i}", stat = "Sum", visible = false }]
            ],
            [
              for i, phase in local.phase_names :
              [{ expression = "m${i}/PERIOD(m${i})", label = phase, id = "e${i}" }]
            ],
          )
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 10
        width  = 12
        height = 7
        properties = {
          title    = "Response time, ${local.judged_phase} phase, expected responses"
          view     = "timeSeries"
          region   = var.aws_region
          period   = local.dashboard_period
          liveData = true
          yAxis = {
            left = {
              label     = "ms"
              min       = 0
              showUnits = false
            }
          }
          annotations = {
            horizontal = [
              {
                # The sizing ceiling, which is also the request timeout and the
                # figure the run is judged against. One number, drawn once.
                label = "latency ceiling"
                value = var.latency_ceiling_ms
                fill  = "above"
              },
            ]
          }
          metrics = [
            for stat in local.latency_statistics :
            [var.metric_namespace, "RequestDuration", local.fleet_dim_name, local.fleet_dim_value, local.phase_dim_name, local.judged_phase, { stat = stat, label = stat }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 17
        width  = 12
        height = 7
        properties = {
          title    = "Failures and drops by phase"
          view     = "timeSeries"
          stacked  = false
          region   = var.aws_region
          period   = local.dashboard_period
          liveData = true
          yAxis = {
            left = {
              min       = 0
              showUnits = false
            }
          }
          metrics = concat(
            [
              for phase in local.phase_names :
              [var.metric_namespace, "RequestsFailed", local.fleet_dim_name, local.fleet_dim_value, local.phase_dim_name, phase, { stat = "Sum", label = "failed: ${phase}" }]
            ],
            [
              # Kept on the same graph on purpose. A dropped iteration is the
              # generator admitting it never made the request, so a failure
              # count rising while drops rise with it is the fleet's shortfall
              # rather than the target's.
              [var.metric_namespace, "IterationsDropped", local.fleet_dim_name, local.fleet_dim_value, { stat = "Sum", label = "dropped by the generator" }]
            ],
          )
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 17
        width  = 12
        height = 7
        properties = {
          title  = "What the workers reported about themselves"
          region = var.aws_region
          view   = "table"
          # The findings a scenario prints before it generates anything: a
          # profile whose population exceeds the socket budget, a threshold
          # that covers nothing, a contract value the worker refused. Each one
          # describes a run that would otherwise PASS without having measured
          # what it claims. The query is a string the API does not check
          # against this log group, so a renamed group leaves this erroring at
          # render time and nowhere else.
          query = join(" ", [
            "SOURCE '${aws_cloudwatch_log_group.runners.name}'",
            "| fields @timestamp, @logStream, @message",
            "| filter @message like /warn|error|Error/",
            "| sort @timestamp desc",
            "| limit 100",
          ])
        }
      },
    ],
  )

  fleet_widgets = concat(
    [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 5
        properties = {
          markdown = local.fleet_preamble
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 5
        width  = 12
        height = 7
        properties = {
          title    = "Connections held per worker, against the socket budget"
          view     = "timeSeries"
          region   = var.aws_region
          period   = local.dashboard_period
          liveData = true
          yAxis = {
            left = {
              label     = "four-tuples"
              min       = 0
              showUnits = false
            }
          }
          annotations = {
            horizontal = [
              {
                # The budget the fleet size was divided by. A worker at this
                # line is the ceiling the whole sizing arithmetic rests on,
                # drawn where it can be seen rather than left in an output.
                label = "socket budget per worker (${local.tuple_budget_source})"
                value = local.effective_tuple_budget
                fill  = "above"
              },
            ]
          }
          metrics = [
            [var.metric_namespace, "ConnectionsHeld", local.fleet_dim_name, local.fleet_dim_value, { stat = "Maximum", label = "busiest worker" }],
            [var.metric_namespace, "ConnectionsHeld", local.fleet_dim_name, local.fleet_dim_value, { stat = "Average", label = "fleet average" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 5
        width  = 12
        height = 7
        properties = {
          title    = "Population in use"
          view     = "timeSeries"
          region   = var.aws_region
          period   = local.dashboard_period
          liveData = true
          yAxis = {
            left = {
              label     = "virtual users"
              min       = 0
              showUnits = false
            }
          }
          metrics = [
            [var.metric_namespace, "VirtualUsersActive", local.fleet_dim_name, local.fleet_dim_value, { stat = "Maximum", label = "busiest worker" }],
            [var.metric_namespace, "VirtualUsersActive", local.fleet_dim_name, local.fleet_dim_value, { stat = "Sum", label = "fleet total" }],
          ]
        }
      },
    ],
    local.fleet_metrics_available ? [
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 7
        properties = {
          title    = "Generator processor and memory"
          view     = "timeSeries"
          region   = var.aws_region
          period   = local.dashboard_period
          liveData = true
          yAxis = {
            left = {
              min       = 0
              showUnits = false
            }
          }
          metrics = [
            ["ECS/ContainerInsights", "CpuUtilized", "ClusterName", aws_ecs_cluster.runners.name, { stat = "Average", label = "vCPU units used" }],
            ["ECS/ContainerInsights", "CpuReserved", "ClusterName", aws_ecs_cluster.runners.name, { stat = "Average", label = "vCPU units reserved" }],
            ["ECS/ContainerInsights", "MemoryUtilized", "ClusterName", aws_ecs_cluster.runners.name, { stat = "Average", label = "MiB used" }],
            ["ECS/ContainerInsights", "MemoryReserved", "ClusterName", aws_ecs_cluster.runners.name, { stat = "Average", label = "MiB reserved" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 7
        properties = {
          title    = "Workers running"
          view     = "timeSeries"
          region   = var.aws_region
          period   = local.dashboard_period
          liveData = true
          yAxis = {
            left = {
              label     = "tasks"
              min       = 0
              showUnits = false
            }
          }
          annotations = {
            horizontal = [
              {
                # What the objective derived. A run below this line offered
                # less load than its target says, and no figure on the target
                # view reports that.
                label = "workers the objective derived"
                value = local.derived_worker_count
                fill  = "below"
              },
            ]
          }
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.runners.name, { stat = "Maximum", label = "running" }],
          ]
        }
      },
    ] : [],
    [
      {
        type   = "log"
        x      = 0
        y      = 19
        width  = 24
        height = 6
        properties = {
          title  = "Workers that stopped before the run did"
          region = var.aws_region
          view   = "table"
          # The only trace a worker leaves if it never reached the start
          # instant or was taken away during the run. A worker absent from a
          # run is otherwise indistinguishable from one that offered no load.
          query = join(" ", [
            "SOURCE '${aws_cloudwatch_log_group.runners.name}'",
            "| fields @timestamp, @logStream, @message",
            "| filter @message like /SIGTERM|interrupt|reclaim|teardown|exiting/",
            "| sort @timestamp desc",
            "| limit 100",
          ])
        }
      },
    ],
  )
}

resource "aws_cloudwatch_dashboard" "run" {
  count = local.dashboards_enabled ? 1 : 0

  # A dashboard name admits only letters, digits, hyphen and underscore - a
  # narrower set than a tag value or a bucket name. name_prefix is already
  # restricted to lowercase letters, digits and hyphens, so this cannot fail
  # on that account.
  dashboard_name = "${var.name_prefix}-run"

  dashboard_body = jsonencode({
    start = var.dashboard_default_range
    # inherit, not auto. Under auto, widening the time range re-periods every
    # graph on the page, and a percentile over a wider period is a different
    # quantity reported under the same label.
    periodOverride = "inherit"
    widgets        = local.run_widgets
  })
}

resource "aws_cloudwatch_dashboard" "fleet" {
  count = local.dashboards_enabled ? 1 : 0

  dashboard_name = "${var.name_prefix}-fleet"

  dashboard_body = jsonencode({
    start          = var.dashboard_default_range
    periodOverride = "inherit"
    widgets        = local.fleet_widgets
  })
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

resource "terraform_data" "dashboard_preconditions" {
  input = {
    period  = local.dashboard_period
    phases  = local.phase_names
    widgets = local.dashboards_enabled ? length(local.run_widgets) + length(local.fleet_widgets) : 0
  }

  lifecycle {
    precondition {
      condition     = local.flushes_per_period == floor(local.flushes_per_period) && local.flushes_per_period >= 1
      error_message = "A ${local.dashboard_period}s period contains ${local.flushes_per_period} flushes at result_flush_seconds of ${var.result_flush_seconds}. The worker count on the dashboard is the flush count divided by this, so a fractional value makes that figure wrong by the remainder - choose a flush interval that divides the period."
    }

    precondition {
      condition     = contains(local.phase_names, local.judged_phase)
      error_message = "The judged phase ${local.judged_phase} is not among the phases the scenario library defines (${join(", ", local.phase_names)}). A latency widget scoped to a phase no run emits renders blank on a dashboard that applied cleanly."
    }

    # Neither page can currently reach this: the widget lists are literal apart
    # from one entry per phase, and the phase set comes from a handful of
    # profiles. It is here for the edit that charts something per run or per
    # scenario, which is where a widget count stops being bounded by hand.
    precondition {
      condition     = !local.dashboards_enabled || max(length(local.run_widgets), length(local.fleet_widgets)) <= 500
      error_message = "A dashboard carries more than 500 widgets: the run page has ${length(local.run_widgets)} and the fleet page ${length(local.fleet_widgets)}, against a limit of 500 per dashboard."
    }
  }
}

# Reported rather than refused: high-resolution publication is a legitimate
# choice whose consequences land somewhere other than where it is configured.
check "high_resolution_metrics_are_not_chartable_here" {
  assert {
    condition     = var.metric_resolution_seconds >= 60
    error_message = "metric_resolution_seconds is ${var.metric_resolution_seconds}, so the workers publish at sub-minute resolution. A dashboard widget's period cannot go below 60, so the extra resolution is not visible on either page, and sub-minute data is retained for hours rather than weeks - so it is also gone by the time anyone reads the run. It is worth having only if something other than these dashboards reads it within that window."
  }
}

# Reported rather than refused: disabling cluster metric collection is a cost
# decision, and this says what it costs.
check "fleet_view_has_generator_metrics" {
  assert {
    condition     = local.fleet_metrics_available
    error_message = "container_insights is disabled, so the fleet view has no processor or memory figures for the workers. Those are what settle whether a rate that stopped rising was the target or the generator, and without them that question is answerable only by inference."
  }
}
