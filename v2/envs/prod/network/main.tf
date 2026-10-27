###
# prod / network — SEPARATE ACCOUNT. Code-only placeholder: present in the
# architecture, NOT applied. Fill the account/profile/bucket once a prod
# account exists, then apply.
#
# DO NOT APPLY until <PROD_ACCOUNT_ID> / profile "prod" / prod state bucket exist.
###
terraform {
  required_version = "~> 1.8"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
  backend "s3" {
    bucket         = "eks-practice-tfstate-PROD_ACCOUNT_ID" # TODO: prod account bucket
    key            = "v2/prod/network/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "eks-practice-tflock"
    encrypt        = true
    profile        = "prod" # TODO: prod account profile
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

module "network" {
  source             = "../../../modules/network"
  name               = local.cluster_name
  cidr               = "10.40.0.0/16"
  azs                = ["ap-southeast-2a", "ap-southeast-2b", "ap-southeast-2c"] # 3 AZ for prod
  cluster_name       = local.cluster_name
  single_nat_gateway = false # prod: NAT per AZ (HA)
  tags               = local.tags
}

output "vpc_id" { value = module.network.vpc_id }
output "private_subnet_ids" { value = module.network.private_subnet_ids }
output "public_subnet_ids" { value = module.network.public_subnet_ids }
