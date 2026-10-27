variable "environment" {
  description = "Environment name (dev/staging/prod) — also a cluster Secret label."
  type        = string
}

variable "gitops_metadata" {
  description = "Metadata map from the cluster layer, written as ArgoCD cluster Secret annotations."
  type        = map(string)
}

variable "addons" {
  description = "Addon enable flags consumed by the addons ApplicationSet (e.g. enable_karpenter=true)."
  type        = map(string)
  default     = {}
}
