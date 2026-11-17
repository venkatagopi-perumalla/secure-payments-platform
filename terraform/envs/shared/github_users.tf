data "aws_caller_identity" "me" {}

locals {
  name       = "payments"
  account_id = data.aws_caller_identity.me.account_id

  # Names that the dev environment gives these on Day 14
  service_arn   = "arn:aws:ecs:${var.region}:${local.account_id}:service/${local.name}/${local.name}-api"
  exec_role_arn = "arn:aws:iam::${local.account_id}:role/${local.name}-ecs-exec"
  task_role_arn = "arn:aws:iam::${local.account_id}:role/${local.name}-ecs-task"
}

# Build user: used by ci.yml, can only push images
resource "aws_iam_user" "ci" {
  name          = "${local.name}-github-ci"
  force_destroy = true
}

data "aws_iam_policy_document" "ci_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.api.arn]
  }
}

resource "aws_iam_user_policy" "ci_push" {
  name   = "push-payments-api-image"
  user   = aws_iam_user.ci.name
  policy = data.aws_iam_policy_document.ci_push.json
}

# Deploy user: used by deploy.yml and rollback.yml, only after approval
resource "aws_iam_user" "deploy" {
  name          = "${local.name}-github-deploy"
  force_destroy = true
}

data "aws_iam_policy_document" "deploy" {
  statement {
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [local.service_arn]
  }
  statement {
    actions   = ["iam:PassRole"]
    resources = [local.exec_role_arn, local.task_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
  statement {
    actions   = ["ecr:DescribeImages"]
    resources = [aws_ecr_repository.api.arn]
  }
}

resource "aws_iam_user_policy" "deploy" {
  name   = "deploy-payments-api"
  user   = aws_iam_user.deploy.name
  policy = data.aws_iam_policy_document.deploy.json
}
