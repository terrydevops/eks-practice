variable "name" {
  description = "VPC name (usually the environment, e.g. dev)."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR."
  type        = string
}

variable "azs" {
  description = "Availability zones to span."
  type        = list(string)
}

variable "cluster_name" {
  description = "EKS cluster name (used in the karpenter.sh/discovery subnet tag)."
  type        = string
}

variable "single_nat_gateway" {
  description = "One NAT gateway (cheap, non-prod) vs one per AZ (HA, prod)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
