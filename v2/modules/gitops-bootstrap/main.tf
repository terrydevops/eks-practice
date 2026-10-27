###
# GitOps bootstrap — the ONLY layer that touches the cluster (helm/kubernetes
# providers), so this layer's plan/apply is gated to protected branches.
#
# It does three things via the GitOps Bridge module:
#   1. install ArgoCD (helm)
#   2. write the cluster's metadata (from the cluster layer) onto the ArgoCD
#      cluster Secret as annotations  ← the "bridge"
#   3. create the root app-of-apps Application pointing at gitops/ in this repo
#
# After this, ALL addons + apps are managed by ArgoCD from git. Terraform never
# installs another Helm chart.
###
module "gitops_bridge_bootstrap" {
  source  = "gitops-bridge-dev/gitops-bridge/helm"
  version = "~> 0.1"

  cluster = {
    cluster_name = var.gitops_metadata.aws_cluster_name
    environment  = var.environment
    metadata     = var.gitops_metadata # -> ArgoCD cluster Secret annotations
    addons       = var.addons          # enable flags consumed by the ApplicationSet
  }

  # Root app-of-apps: ArgoCD then renders addons + apps from these git paths.
  apps = {
    bootstrap = file("${path.module}/bootstrap-app.yaml")
  }

  install = true # install ArgoCD via helm
}
