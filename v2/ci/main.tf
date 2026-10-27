###
# CI/CD identity layer (AWS only) — GitLab OIDC provider + the roles the pipeline
# assumes. No long-lived keys, no protected CI variables.
#
#   plan role  : any branch may assume it; ReadOnlyAccess only, NO cluster access
#                -> feature branches can `plan` the network/cluster (AWS) layers.
#   apply role : only PROTECTED branches (gitlab.com:ref_protected=true) may assume;
#                AdministratorAccess + an EKS ClusterAdmin access entry so it can
#                apply every layer including gitops (which touches the cluster).
#
# This is the v2 payoff: the AWS layers have no cluster dependency, so plan is
# safe on any branch; only the cluster-touching gitops layer is gated to protected.
###
terraform {
  required_version = "~> 1.8"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
  backend "s3" {
    bucket         = "__TF_STATE_BUCKET__"
    key            = "v2/ci/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "eks-practice-tflock"
    encrypt        = true
    profile        = "k8s-sub"
  }
}

provider "aws" {
  region  = "ap-southeast-2"
  profile = var.aws_profile != "" ? var.aws_profile : null
  default_tags {
    tags = {
      project    = "eks-practice"
      managed-by = "terraform"
      layer      = "ci"
    }
  }
}

variable "aws_profile" {
  type    = string
  default = "k8s-sub"
}

variable "gitlab_project_path" {
  type    = string
  default = "__GITLAB_PROJECT__"
}

variable "gitlab_aud" {
  description = "Audience the GitLab id_token requests (must match .gitlab-ci.yml id_tokens aud)."
  type        = string
  default     = "https://gitlab.com"
}

variable "cluster_name" {
  type    = string
  default = "eks-practice-nonprod"
}

locals {
  gitlab_host = "gitlab.com"
}

###
# GitLab OIDC provider (one per AWS account).
###
data "tls_certificate" "gitlab" {
  url = "https://${local.gitlab_host}"
}

resource "aws_iam_openid_connect_provider" "gitlab" {
  url             = "https://${local.gitlab_host}"
  client_id_list  = [var.gitlab_aud]
  thumbprint_list = [data.tls_certificate.gitlab.certificates[0].sha1_fingerprint]
}

###
# Plan role — any branch in this project, read-only.
###
data "aws_iam_policy_document" "plan_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.gitlab_host}:aud"
      values   = [var.gitlab_aud]
    }
    condition {
      test     = "StringLike"
      variable = "${local.gitlab_host}:sub"
      values   = ["project_path:${var.gitlab_project_path}:*"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "eks-practice-gitlab-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# The cluster layer configures an aws.dns provider that assumes the cross-account
# eks-practice-dns role (to plan ACM validation records). ReadOnlyAccess does NOT
# include sts:AssumeRole, so the plan role needs this scoped grant to plan that
# layer. It can only READ via the assumed role during plan (no apply), and the
# grant is limited to that one role ARN.
resource "aws_iam_role_policy" "plan_assume_dns" {
  name = "assume-cross-account-dns-readonly"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "__DNS_ROLE_ARN__"
    }]
  })
}

###
# Apply role — protected branches only, admin + cluster access.
###
data "aws_iam_policy_document" "apply_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.gitlab_host}:aud"
      values   = [var.gitlab_aud]
    }
    condition {
      test     = "StringLike"
      variable = "${local.gitlab_host}:sub"
      values   = ["project_path:${var.gitlab_project_path}:*"]
    }
    # Only pipelines running on a PROTECTED branch/tag may assume this role.
    condition {
      test     = "StringEquals"
      variable = "${local.gitlab_host}:ref_protected"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "eks-practice-gitlab-apply"
  assume_role_policy   = data.aws_iam_policy_document.apply_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

###
# Cluster access for the apply role (so the gitops layer's helm/k8s apply works).
# Created here referencing the existing cluster by name.
###
resource "aws_eks_access_entry" "apply" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.apply.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "apply_admin" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.apply.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.apply]
}

output "plan_role_arn" { value = aws_iam_role.plan.arn }
output "apply_role_arn" { value = aws_iam_role.apply.arn }
output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.gitlab.arn }
