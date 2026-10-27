# Chaos experiments (codified, manual-sync)

Chaos Mesh CRs kept in git so experiments are reproducible and reviewable instead
of clicked ad-hoc through the dashboard. Each has an explicit **steady-state
hypothesis** — the SLO/probe signal that must hold — so an experiment has a
pass/fail verdict, not just "we broke something".

| File | Kind | Blast radius | Watch |
| --- | --- | --- | --- |
| `podchaos-whoami-pod-kill.yaml` | PodChaos | kill 1 whoami pod (staging) | availability stays up |
| `networkchaos-whoami-delay.yaml` | NetworkChaos | +200ms egress, 2m | latency panel / latency SLO |
| `stresschaos-whoami-cpu.yaml` | StressChaos | 80% of 1 CPU, 2m | CPU panel, no SLO breach |
| `schedule-whoami-pod-kill.yaml` | Schedule | weekly pod-kill (Mon 03:00) | continuous verification |

## Why manual-sync

The `chaos-experiments` ArgoCD Application (`../addons/chaos-experiments.yaml`)
has **no `automated` sync policy** — these CRs are version-controlled but stay
dormant until someone deliberately syncs the app (or `kubectl apply`s a single
file). This keeps fault injection an opt-in action, never something an ArgoCD
auto-sync fires on its own. The `Schedule` is the exception by design: once
applied it runs on its cron until deleted — that's the standing resilience check.

## Running one

```sh
# ad-hoc single experiment
kubectl apply -f podchaos-whoami-pod-kill.yaml
# ...watch the "Chaos Engineering — whoami" Grafana dashboard...
kubectl delete -f podchaos-whoami-pod-kill.yaml

# or sync the whole set (incl. the weekly Schedule) from the ArgoCD UI:
#   argocd app sync chaos-experiments
```

## Reuse in another project

Change `selector.namespaces` (`whoami-staging-app`) and `labelSelectors`
(`app: whoami`) to your workload, and confirm the target cluster's chaos-daemon
socket matches the node runtime (see `../addons/chaos-mesh.yaml`). PodChaos is
API-level and portable; Network/Stress/IO chaos need the daemon socket right.
