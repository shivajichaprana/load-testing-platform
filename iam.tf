# ---------------------------------------------------------------------------
# Two roles, which are routinely collapsed into one
#
#   execution role  Assumed by the platform's agent, not by the scenario. It
#                   pulls the image and opens the log stream. Nothing the
#                   scenario runs can use it.
#
#   task role       Assumed by the code inside the container. Everything the
#                   scenario itself reaches - results, parameters, metrics -
#                   belongs here.
#
# The shortcut is to put the result-writing permission on the execution role
# because that is the role already attached and already working. It is not
# equivalent: an execution role is commonly shared across every task definition
# in an account, so a permission added there is granted to all of them, and the
# blast radius of the grant has nothing to do with this fleet.
# ---------------------------------------------------------------------------

# The service principal must be allowed to assume both roles. The two condition
# keys below are the confused-deputy guard.
#
# Note the wildcard: scoping this to a single cluster is NOT supported, so the
# ARN pattern has to admit every cluster in the account and region. Tightening
# it to this cluster looks like an improvement and stops every task in the
# fleet from starting.
data "aws_iam_policy_document" "runner_assume_role" {
  statement {
    sid     = "AllowTaskServiceToAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

# ---------------------------------------------------------------------------
# Execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "runner_execution" {
  name               = "${var.name_prefix}-runner-execution"
  description        = "Pulls the runner image and opens the log stream. Not reachable from inside the container."
  assume_role_policy = data.aws_iam_policy_document.runner_assume_role.json
}

data "aws_iam_policy_document" "runner_execution" {
  # The log group is created here, so the stream permission is scoped to it
  # rather than to the account's log groups at large.
  statement {
    sid    = "WriteRunnerLogStreams"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.runners.arn}:*"]
  }

  # This action takes no resource at all: the token it returns is scoped to the
  # caller's registry, not to a repository, so there is nothing narrower to
  # name. Attempts to scope it produce a policy that denies every image pull.
  statement {
    sid       = "AuthenticateToRegistry"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # The layer reads ARE scoped, when the image comes from a private repository
  # whose ARN was supplied. A public registry has no ARN to scope to, so the
  # statement is omitted rather than widened to every repository in the
  # account.
  dynamic "statement" {
    for_each = var.runner_image_repository_arn == null ? [] : [var.runner_image_repository_arn]

    content {
      sid    = "PullRunnerImage"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "runner_execution" {
  name   = "runner-execution"
  role   = aws_iam_role.runner_execution.id
  policy = data.aws_iam_policy_document.runner_execution.json
}

# ---------------------------------------------------------------------------
# Task role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "runner_task" {
  name               = "${var.name_prefix}-runner-task"
  description        = "Assumed by the scenario. Streams results, reads its run parameters, publishes its own metrics."
  assume_role_policy = data.aws_iam_policy_document.runner_assume_role.json
}

data "aws_iam_policy_document" "runner_task" {
  # Publishing a metric takes no resource either, so the namespace condition is
  # the only boundary this action has. Without it the grant is "publish any
  # metric anywhere in the account", which includes overwriting the series
  # another system reads.
  statement {
    sid       = "PublishRunnerMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metric_namespace]
    }
  }

  # The run's own parameters, under a prefix derived from this fleet's name.
  statement {
    sid    = "ReadRunParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.name_prefix}/run/*",
    ]
  }

  # Write-only, and only beneath this fleet's prefix. A runner has no reason to
  # read a previous run's results, and a generator that can delete them is one
  # bad scenario away from destroying the baseline it is being compared to.
  dynamic "statement" {
    for_each = var.run_artifact_bucket_name == null ? [] : [var.run_artifact_bucket_name]

    content {
      sid    = "StreamRunResults"
      effect = "Allow"
      actions = [
        "s3:AbortMultipartUpload",
        "s3:PutObject",
      ]
      resources = [
        "arn:${data.aws_partition.current.partition}:s3:::${statement.value}/${var.name_prefix}/runs/*",
      ]
    }
  }
}

resource "aws_iam_role_policy" "runner_task" {
  name   = "runner-task"
  role   = aws_iam_role.runner_task.id
  policy = data.aws_iam_policy_document.runner_task.json
}
