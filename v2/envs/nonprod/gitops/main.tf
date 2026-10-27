###
# non-prod / gitops layer — the ONLY layer with helm/kubernetes providers, so it is
# the ONLY one that touches the cluster. CI gates its plan/apply to protected
# branches. Installs ArgoCD + writes the GitOps Bridge metadata + root app.
###
terraform {
  required_version = "~> 1.8"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.60" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
  }
  backend "s3" {
    bucket         = "__TF_STATE_BUCKET__"
    key            = "v2/nonprod/gitops/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "eks-practice-tflock"
    encrypt        = true
    profile        = "k8s-sub"
  }
}

variable "aws_profile" {
  type    = string
  default = "k8s-sub"
}

locals {
  region       = "ap-southeast-2"
  cluster_name = "eks-practice-nonprod"
}

# Configures the aws provider that data.aws_eks_cluster uses (region + profile).
# This layer creates no AWS resources; it only reads the cluster to auth helm/k8s.
provider "aws" {
  region  = local.region
  profile = var.aws_profile != "" ? var.aws_profile : null
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket  = "__TF_STATE_BUCKET__"
    key     = "v2/nonprod/cluster/terraform.tfstate"
    region  = "ap-southeast-2"
    profile = var.aws_profile != "" ? var.aws_profile : null # null in CI -> OIDC creds
  }
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

# Token via the AWS provider (NO aws-CLI exec). The AWS provider is configured
# with the local profile (k8s-sub) or CI's OIDC web-identity creds, and mints the
# cluster token directly — works in both places and avoids the brittle aws-cli
# exec (exit 255 / expat symbol errors in CI images).
data "aws_eks_cluster_auth" "this" {
  name = local.cluster_name
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

module "gitops" {
  source = "../../../modules/gitops-bootstrap"

  environment     = "nonprod"
  gitops_metadata = data.terraform_remote_state.cluster.outputs.gitops_metadata
  addons = {
    enable_metrics_server         = "true"
    enable_ingress_nginx          = "true"
    enable_karpenter              = "true"
    enable_aws_load_balancer_ctrl = "true"
    enable_kube_prometheus_stack  = "true"
  }
}
