###
# prod / cluster — SEPARATE ACCOUNT, code-only placeholder. NOT applied.
# DO NOT APPLY until the prod account/backend exist (see network).
###
terraform {
  required_version = "~> 1.8"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
  backend "s3" {
    bucket         = "eks-practice-tfstate-PROD_ACCOUNT_ID" # TODO: prod account bucket
    key            = "v2/prod/cluster/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "eks-practice-tflock"
    encrypt        = true
    profile        = "prod" # TODO
  }
}

provider "aws" {
  region  = "ap-southeast-2"
  profile = var.aws_profile != "" ? var.aws_profile : null
  default_tags { tags = local.tags }
}

variable "aws_profile" {
  type    = string
  default = "prod"
}

locals {
  cluster_name = "eks-practice-prod"
  tags = {
    project     = "eks-practice"
    environment = "prod"
    managed-by  = "terraform"
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-PROD_ACCOUNT_ID" # TODO
    key     = "v2/prod/network/terraform.tfstate"
    region  = "ap-southeast-2"
    profile = "prod" # TODO
  }
}

module "cluster" {
  source             = "../../../modules/cluster"
  cluster_name       = local.cluster_name
  cluster_version    = "1.34"
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
  tags               = local.tags
  # prod hardening to add here: private API endpoint, larger node group, etc.
}

output "cluster_name" { value = module.cluster.cluster_name }
output "gitops_metadata" { value = module.cluster.gitops_metadata }
