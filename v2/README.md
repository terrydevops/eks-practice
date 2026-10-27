# eks-practice v2

Clean rebuild. The v1 flaw was mixing AWS + Kubernetes/Helm in one Terraform
state, which forced CI plan to reach the cluster (exit 255, EKS access entries,
reading Helm Secrets, cluster-admin to all branches). v2 fixes it by principle:

> **Terraform = AWS only. ArgoCD = everything in-cluster.**

So the AWS layers have no cluster dependency and feature branches plan them
safely — no state-split surgery needed.

## Layers (per environment)

```
network   (AWS only)  ── VPC, subnets, NAT                 → feature-plannable
   ▼ remote_state
cluster   (AWS only)  ── EKS, Bottlerocket node group,     → feature-plannable
                         Karpenter AWS+PodIdentity, OIDC,
                         emits gitops_metadata
   ▼ remote_state
gitops    (k8s/helm)  ── installs ArgoCD + writes GitOps    → PROTECTED branches
                         Bridge metadata + root app-of-apps     (only cluster-touching layer)
```

After the gitops layer, ArgoCD manages all addons + apps from `gitops/`.

## Environments

- **non-prod is one shared cluster** hosting **dev + staging** as separate
  namespaces (`<app>-dev-app`, `<app>-staging-app`), isolated by namespace
  (+ ResourceQuota / NetworkPolicy / RBAC). One control plane, one NAT — cheaper.
- **prod is a separate cluster** in a separate account, with its own ArgoCD.
- The `apps` ApplicationSet on the shared cluster deploys only `overlays/dev` and
  `overlays/staging`; `overlays/prod` is deployed by the prod cluster's ArgoCD.

## Directory map

```
v2/
├── modules/
│   ├── network/            # terraform-aws-modules/vpc wrapper + EKS/Karpenter tags
│   ├── cluster/            # terraform-aws-modules/eks + karpenter + gitops_metadata output
│   └── gitops-bootstrap/   # gitops-bridge: ArgoCD + cluster-secret metadata + root app
├── envs/
│   ├── nonprod/{network,cluster,gitops}/   # SHARED cluster eks-practice-nonprod (dev + staging)
│   └── prod/{network,cluster,gitops}/      # separate cluster + account   [TODO]
└── gitops/                 # ArgoCD-watched (the k8s side)
    ├── bootstrap/          # AppProjects (platform/apps) + addons & apps ApplicationSets
    ├── addons/             # platform addons (templated from bridge metadata)
    └── apps/whoami/        # business app: base + overlays/{dev,staging,prod}
```

## Apply order (non-prod)

```bash
cd v2/envs/nonprod/network && terraform init && terraform apply
cd ../cluster              && terraform init && terraform apply
cd ../gitops               && terraform init && terraform apply   # protected only
# then ArgoCD reconciles gitops/ — addons + apps appear.
```

## What's baked in from the v1 review

- Pinned provider versions (`~>`, not open `>=`).
- whoami runs **restricted / non-root / read-only rootfs** (v1 ran root).
- Platform/app **AppProjects**; apps fenced to `*-app` namespaces.
- Prefix delegation + Bottlerocket + (planned) Graviton/spot NodePools.
- Borrowed from cluster-platform-demo: directory-as-onboarding ApplicationSet,
  and (planned) conftest/OPA gates (`no_latest_tag`, `no_cluster_admin_for_app_sa`, …).

## Status

Validated end-to-end on the shared non-prod cluster `eks-practice-nonprod`
(one cluster hosts dev + staging as separate namespaces):

- network + cluster + gitops all applied; ArgoCD healthy.
- `apps` ApplicationSet deploys whoami into `whoami-dev-app` and `whoami-staging-app`.

Still to fill: per-addon Application files under `addons/` (platform layer is
empty), namespace ResourceQuota/NetworkPolicy isolation, OPA/conftest gates,
CI per-layer pipelines, and the prod cluster. v1 (repo root) is destroyed.
