output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

###
# GitOps Bridge metadata — written by the gitops layer onto the ArgoCD cluster
# Secret as annotations; the addons ApplicationSet reads them to template Helm
# values (so e.g. Karpenter's NodePool/values know the node role + SQS queue
# WITHOUT Terraform installing the chart). This is the IaC -> GitOps handoff.
###
output "gitops_metadata" {
  description = "Annotations for the ArgoCD cluster Secret (GitOps Bridge)."
  value = {
    aws_cluster_name = module.eks.cluster_name
    aws_region       = data.aws_region.current.name
    aws_account_id   = data.aws_caller_identity.current.account_id

    # Karpenter (Pod Identity, so no role ARN annotation needed on the SA, but
    # the NodePool/values still need the node role name and interruption queue).
    karpenter_node_iam_role_name = module.karpenter.node_iam_role_name
    karpenter_sqs_queue_name     = module.karpenter.queue_name
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
