###
# prod / gitops — SEPARATE ACCOUNT, code-only placeholder. NOT applied.
# Only cluster-touching layer (helm/k8s). DO NOT APPLY until prod exists.
#
# Production note: prod apps should sync MANUALLY (no automated sync) and the
# prod AppProject should add syncWindows. A hub-spoke ArgoCD (one fleet ArgoCD
# managing dev/staging/prod) is the scale option instead of ArgoCD-per-cluster.
###
terraform {
  required_version = "~> 1.8"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.60" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
  }
  backend "s3" {
    bucket         = "eks-practice-tfstate-PROD_ACCOUNT_ID" # TODO
    key            = "v2/prod/gitops/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "eks-practice-tflock"
    encrypt        = true
    profile        = "prod" # TODO
  }
}

variable "aws_profile" {
  type    = string
  default = "prod"
}

locals {
  region       = "ap-southeast-2"
  cluster_name = "eks-practice-prod"
  exec_args = concat(
    ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.region],
    var.aws_profile != "" ? ["--profile", var.aws_profile] : []
  )
}

# Configures the aws provider that data.aws_eks_cluster uses (region + profile).
provider "aws" {
  region  = local.region
  profile = var.aws_profile != "" ? var.aws_profile : null
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-PROD_ACCOUNT_ID" # TODO
    key     = "v2/prod/cluster/terraform.tfstate"
    region  = "ap-southeast-2"
    profile = "prod" # TODO
  }
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.exec_args
    }
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}

module "gitops" {
  source          = "../../../modules/gitops-bootstrap"
  environment     = "prod"
  gitops_metadata = data.terraform_remote_state.cluster.outputs.gitops_metadata
  addons = {
    enable_metrics_server         = "true"
    enable_ingress_nginx          = "true"
    enable_karpenter              = "true"
    enable_aws_load_balancer_ctrl = "true"
    enable_kube_prometheus_stack  = "true"
  }
}
