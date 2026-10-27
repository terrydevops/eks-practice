# Platform addons (ArgoCD-managed)

Each platform addon lives here as an ArgoCD Application (Helm chart from upstream
+ inline values) or a small Kustomize/Helm bundle. The `addons` ApplicationSet
(`../bootstrap/applicationsets.yaml`) renders these per cluster, templating
values from the **GitOps Bridge metadata** on the ArgoCD cluster Secret (region,
Karpenter node role / SQS queue, enable flags) — so Terraform never installs a
Helm chart.

Planned addons (migrated off the v1 Terraform helm provider):

| Addon | Notes |
| --- | --- |
| metrics-server | pure helm |
| ingress-nginx | pure helm |
| cert-manager | pure helm |
| external-dns | IRSA/Pod Identity from bridge |
| external-secrets | secrets management (v1 gap) |
| aws-load-balancer-controller | IRSA role from bridge metadata |
| karpenter | helm + EC2NodeClass/NodePool (Graviton+spot); node role/SQS from bridge |
| kube-prometheus-stack | Prometheus + Grafana + Karpenter ServiceMonitor |
| kyverno | policy engine + custom ClusterPolicies (Audit) in `kyverno-policies/` |
| velero | backup (v1 gap) |

Skeleton: wiring is in place; per-addon Application files are added incrementally.

## Observability, SLO & chaos

Deployed and wired together (all ArgoCD-managed, no Terraform helm):

| Addon / file | What it does |
| --- | --- |
| `kube-prometheus-stack.yaml` | Prometheus (gp3 PVC, 15d retention) + Grafana + Alertmanager (Slack receiver, webhook from SSM via ESO) |
| `blackbox-exporter.yaml` | synthetic HTTP prober — the external "user's-eye" SLI source |
| `pyrra.yaml` | SLO manager + UI; watches `ServiceLevelObjective` CRs and generates multi-window burn-rate rules (Google SRE style) |
| `service-slo.yaml` → `../charts/service-slo` | reusable chart: one Probe + per-service availability/latency SLOs (whoami staging + dev). Replaces the old hand-written `whoami-probe.yaml` / `whoami-slo.yaml` |
| `chaos-mesh.yaml` | chaos-engineering toolkit (Pod/Network/Stress/IO chaos) + dashboard; chaos-daemon tuned for Bottlerocket/containerd |
| `chaos-experiments.yaml` → `../chaos-experiments/` | **manual-sync** Application: version-controlled experiments (incl. a weekly Schedule), dormant until deliberately synced |
| `chaos-grafana-dashboard.yaml` | "Chaos Engineering — whoami" dashboard: steady-state SLO / pods / nodes panels |
| `karpenter-alerts.yaml` | symptom-based PrometheusRule for dynamic-node churn/limits |

**Reusing this in another project:** the SLO bundle is a parameterised chart
(`../charts/service-slo`) — override `services[]` (host, target, window, latency
threshold) in `service-slo.yaml` or copy the chart. For chaos, change the
`selector` namespace/labels in `../chaos-experiments/` and confirm the target
node runtime's chaos-daemon socket in `chaos-mesh.yaml`. Flip
`chaos-mesh.yaml` `dashboard.securityMode: true` before any non-practice use.

**Known limits (honest):** single-node Prometheus with 15d retention — a real
28-day SLO still needs long-term storage (Thanos/Mimir). The Slack webhook SSM
parameter (`/eks-practice/alertmanager/slack-webhook`) must be populated for
alerts to actually deliver.

## Pod Security Admission (PSA)

PSA enforces the Pod Security Standards at the namespace level; Kyverno
(`kyverno.yaml` + `kyverno-policies/`) adds the finer rules PSA cannot express.

- **App namespaces** (`<app>-<env>-app`) are labelled `restricted` (enforce +
  warn + audit) declaratively via `managedNamespaceMetadata` on the `apps`
  ApplicationSet — see `../bootstrap/applicationsets.yaml`.
- **Platform / system namespaces** are not ArgoCD-managed, so they are labelled
  once (idempotent). node-exporter / Karpenter / CNI need host access, hence
  `privileged`:

  ```bash
  for ns in kube-system kube-node-lease kube-public monitoring; do
    kubectl label ns $ns pod-security.kubernetes.io/enforce=privileged --overwrite
  done
  kubectl label ns argocd \
    pod-security.kubernetes.io/warn=baseline \
    pod-security.kubernetes.io/audit=baseline --overwrite
  for ns in vpa default storage-demo; do
    kubectl label ns $ns \
      pod-security.kubernetes.io/warn=restricted \
      pod-security.kubernetes.io/audit=restricted --overwrite
  done
  ```
