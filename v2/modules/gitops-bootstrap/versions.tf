terraform {
  required_version = "~> 1.8"
  required_providers {
    # This is the ONLY layer with k8s/helm providers -> only layer that needs
    # cluster access -> gated to protected branches in CI.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}
