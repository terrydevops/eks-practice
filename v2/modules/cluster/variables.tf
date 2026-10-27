variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes minor version."
  type        = string
  default     = "1.34"
}

variable "vpc_id" {
  description = "VPC ID (from the network layer)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the control plane and nodes."
  type        = list(string)
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "dns_role_arn" {
  description = "Cross-account Route53 role external-dns assumes (mgmt account)."
  type        = string
  default     = "__DNS_ROLE_ARN__"
}
