###
# non-prod / cluster layer — AWS only -> feature-plannable on any branch.
# Reads the network layer's outputs via remote state.
###
terraform {
  required_version = "~> 1.8"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
  backend "s3" {
    bucket         = "__TF_STATE_BUCKET__"
    key            = "v2/nonprod/cluster/terraform.tfstate"
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
    tags = local.tags
  }
}

# Cross-account Route53: the __BASE_DOMAIN__ zone lives in the mgmt account, so this
# aliased provider assumes eks-practice-dns (bootstrap). Used for ACM DNS validation
# records here; external-dns assumes the same role at runtime for app records.
provider "aws" {
  alias   = "dns"
  region  = "ap-southeast-2"
  profile = var.aws_profile != "" ? var.aws_profile : null
  assume_role {
    role_arn = "__DNS_ROLE_ARN__"
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

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket  = "__TF_STATE_BUCKET__"
    key     = "v2/nonprod/network/terraform.tfstate"
    region  = "ap-southeast-2"
    profile = var.aws_profile != "" ? var.aws_profile : null # null in CI -> OIDC creds
  }
}

module "cluster" {
  source = "../../../modules/cluster"

  cluster_name       = local.cluster_name
  cluster_version    = "1.34"
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
  tags               = local.tags
}

# Wildcard ACM cert for *.__BASE_DOMAIN__ (covers whoami-dev / whoami-staging). The
# ALB controller auto-discovers it by host, so no ARN threading into the Ingress.
# DNS-validated; validation records written cross-account into the mgmt-account zone.
data "aws_route53_zone" "public" {
  provider = aws.dns
  name     = "__BASE_DOMAIN__"
}

resource "aws_acm_certificate" "wildcard" {
  domain_name               = "*.__BASE_DOMAIN__"
  subject_alternative_names = ["__BASE_DOMAIN__"]
  validation_method         = "DNS"
  tags                      = local.tags
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  provider = aws.dns
  for_each = {
    for o in aws_acm_certificate.wildcard.domain_validation_options : o.domain_name => o
  }
  zone_id         = data.aws_route53_zone.public.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

output "cluster_name" { value = module.cluster.cluster_name }
output "gitops_metadata" { value = module.cluster.gitops_metadata }
output "eks_admin_role_arn" { value = module.cluster.eks_admin_role_arn }
output "acm_wildcard_arn" { value = aws_acm_certificate.wildcard.arn }
