output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets (EKS nodes, internal LBs, Karpenter)."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnets (internet-facing LBs, NAT)."
  value       = module.vpc.public_subnets
}

output "intra_subnet_ids" {
  description = "Intra subnets (no NAT route; control-plane ENIs / internal-only)."
  value       = module.vpc.intra_subnets
}
