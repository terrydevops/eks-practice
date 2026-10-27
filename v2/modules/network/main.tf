###
# Network module — AWS-only (no k8s providers), so it is feature-plannable.
# Thin wrapper over terraform-aws-modules/vpc with the subnet tags EKS and
# Karpenter need for discovery. Private subnets host nodes; public host LBs/NAT.
###
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.cidr
  azs  = var.azs

  # /16 + 4 newbits = /20 subnets, numbered 0..15. Three tiers in blocks of 4
  # (private 0-3, public 4-7, intra 8-11) -> fits up to 4 AZ/tier, no overlap.
  private_subnets = [for k, az in var.azs : cidrsubnet(var.cidr, 4, k)]
  public_subnets  = [for k, az in var.azs : cidrsubnet(var.cidr, 4, k + 4)]
  intra_subnets   = [for k, az in var.azs : cidrsubnet(var.cidr, 4, k + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway # true for non-prod (cost), false for prod (HA)
  enable_dns_hostnames = true

  # Public = internet-facing LBs; private = internal LBs + Karpenter discovery.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }

  tags = var.tags
}
