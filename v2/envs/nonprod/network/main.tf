###
# non-prod / network layer — AWS only -> feature-plannable on any branch.
###
terraform {
  required_version = "~> 1.8"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
  backend "s3" {
    bucket         = "__TF_STATE_BUCKET__"
    key            = "v2/nonprod/network/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "eks-practice-tflock"
    encrypt        = true
    profile        = "k8s-sub" # CI overrides with -backend-config="profile="
  }
}

provider "aws" {
  region  = "ap-southeast-2"
  profile = var.aws_profile != "" ? var.aws_profile : null
  default_tags {
    tags = local.tags
  }
}

variable "aws_profile" {
  type    = string
  default = "k8s-sub"
}

locals {
  cluster_name = "eks-practice-nonprod"
  tags = {
    project     = "eks-practice"
    environment = "nonprod"
    managed-by  = "terraform"
  }
}

module "network" {
  source = "../../../modules/network"

  name               = local.cluster_name
  cidr               = "10.20.0.0/16"
  azs                = ["ap-southeast-2a", "ap-southeast-2b"]
  cluster_name       = local.cluster_name
  single_nat_gateway = true # non-prod: one NAT to save cost
  tags               = local.tags
}

output "vpc_id" { value = module.network.vpc_id }
output "private_subnet_ids" { value = module.network.private_subnet_ids }
output "public_subnet_ids" { value = module.network.public_subnet_ids }
