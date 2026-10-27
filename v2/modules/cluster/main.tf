###
# Cluster module — AWS-only (NO kubernetes/helm/kubectl providers), so the
# cluster layer is feature-plannable on any branch. It creates the EKS cluster,
# a small Bottlerocket bootstrap managed node group, Karpenter's AWS side (IAM +
# SQS via Pod Identity), and emits `gitops_metadata` for the GitOps Bridge.
#
# Addons (helm) and apps are NOT installed here — ArgoCD does that (gitops layer).
###
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  # Do NOT bind cluster-admin to whoever runs terraform (that flips the access
  # entry between the local role and the CI role, and could hand admin to the
  # read-only plan role). Instead pin an explicit admin entry below.
  enable_cluster_creator_admin_permissions = false

  access_entries = {
    # Break-glass: the org-wide admin role. Kept so we can never fully lock out,
    # but day-to-day kubectl should use the dedicated eks_admin role below.
    org_admin = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/OrganizationAccountAccessRole"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    # Dedicated cluster-admin identity. The role itself has almost no AWS power
    # (see aws_iam_role.eks_admin) -- its admin is only inside the cluster, via
    # this access entry. This is the least-privilege day-to-day admin.
    eks_admin = {
      principal_arn = aws_iam_role.eks_admin.arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # Pin the KMS key administrator too, for the same reason (no flip per runner).
  kms_key_administrators = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/OrganizationAccountAccessRole"]

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # Base addons managed by EKS (not helm). Prefix delegation for pod density.
  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = {}
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
        enableNetworkPolicy = "true"
      })
    }
  }

  # Small on-demand Bottlerocket bootstrap group; Karpenter handles burst.
  eks_managed_node_groups = {
    bootstrap = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      # Enforce IMDSv2 and hop limit 1 so PODS cannot reach instance metadata
      # (only the host can) -- closes the SSRF->node-credentials path. The module
      # already sets http_tokens=required but defaults hop limit to 2; Karpenter
      # nodes are already at hop 1.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }

  # IRSA still available; Karpenter below uses Pod Identity.
  enable_irsa = true

  # Karpenter discovers the node security group via this tag (subnets are tagged
  # in the network module). Without it, EC2NodeClass finds no SG and can't launch.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = var.tags
}

###
# Karpenter AWS side (IAM role via Pod Identity + SQS interruption queue + node
# IAM role). The Helm install + EC2NodeClass/NodePool live in GitOps.
###
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  enable_pod_identity             = true
  create_pod_identity_association = true

  # Let nodes pull ECR etc.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

###
# EBS CSI driver — enables dynamic PVC -> PV -> EBS volume provisioning.
# AWS side here (IAM role via Pod Identity + the EKS managed addon); the gp3
# StorageClass is delivered via GitOps. Without this, PVCs stay Pending.
###
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"] # EKS Pod Identity trust
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa" # SA the managed addon creates
  role_arn        = aws_iam_role.ebs_csi.arn
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = module.eks.cluster_name
  addon_name   = "aws-ebs-csi-driver"
  tags         = var.tags

  # Driver needs the Pod Identity association to exist before it can assume the role.
  depends_on = [aws_eks_pod_identity_association.ebs_csi]
}

###
# Dedicated cluster-admin role. The point: separate "who can admin the cluster"
# from "who is AWS account admin". This role can be assumed by OrganizationAccount-
# AccessRole, but on the AWS side it can do almost nothing (only describe the
# cluster). All of its power is the in-cluster admin granted by the access entry
# above. So a holder can run kubectl as admin but cannot touch other AWS resources.
###
data "aws_iam_policy_document" "eks_admin_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/OrganizationAccountAccessRole"]
    }
  }
}

resource "aws_iam_role" "eks_admin" {
  name                 = "${var.cluster_name}-eks-admin"
  assume_role_policy   = data.aws_iam_policy_document.eks_admin_assume.json
  max_session_duration = 3600
  tags                 = var.tags
}

# Minimal AWS permissions: just enough to fetch the cluster for kubeconfig.
# Cluster admin itself comes from the EKS access entry, not from IAM.
resource "aws_iam_role_policy" "eks_admin_describe" {
  name = "eks-describe"
  role = aws_iam_role.eks_admin.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

output "eks_admin_role_arn" {
  description = "Dedicated cluster-admin role for day-to-day kubectl (least privilege)."
  value       = aws_iam_role.eks_admin.arn
}

###
# AWS Load Balancer Controller — AWS side (IAM via Pod Identity). The Helm install
# is GitOps. The controller turns Ingress objects into ALBs. (ebs_csi_assume is the
# generic pods.eks.amazonaws.com Pod-Identity trust, reused here.)
###
resource "aws_iam_role" "lb_controller" {
  name               = "${var.cluster_name}-aws-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = var.tags
}

resource "aws_iam_policy" "lb_controller" {
  name   = "${var.cluster_name}-aws-lb-controller"
  policy = file("${path.module}/lb-controller-iam-policy.json")
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
}

###
# external-dns — AWS side. It writes records CROSS-ACCOUNT into __BASE_DOMAIN__ (mgmt
# account) by assuming eks-practice-dns. So its in-cluster role only needs permission
# to assume that role; the Route53 perms live on eks-practice-dns (bootstrap).
###
resource "aws_iam_role" "external_dns" {
  name               = "${var.cluster_name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "external_dns_assume" {
  name = "assume-cross-account-dns"
  role = aws_iam_role.external_dns.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      # TagSession is required alongside AssumeRole: EKS Pod Identity vends this
      # role's creds with transitive session tags, which get forwarded on the
      # chained cross-account assume. Without it external-dns fails with
      # "not authorized to perform: sts:TagSession on .../eks-practice-dns".
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = var.dns_role_arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
}

# External Secrets Operator (ESO) — AWS side. Reads SSM Parameter Store so secrets
# (e.g. the Grafana admin password) live in SSM, not git, and are re-materialized
# on every cluster rebuild. Pod Identity, reusing the generic pods.eks trust.
resource "aws_iam_role" "external_secrets" {
  name               = "${var.cluster_name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy" "external_secrets_ssm" {
  name = "read-ssm-parameters"
  role = aws_iam_role.external_secrets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/eks-practice/*"
      },
      {
        # SecureString parameters are encrypted with the default aws/ssm KMS key;
        # decrypt is needed to read them (read-only, scoped to that AWS-managed key).
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${data.aws_region.current.name}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}
