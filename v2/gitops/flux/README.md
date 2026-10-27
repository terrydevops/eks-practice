# Flux practice (side-by-side with the existing ArgoCD stack)

Goal: learn **Flux v2** hands-on without disturbing the ArgoCD that already runs
this repo. Flux delivers the *same* `whoami` base — via its own controllers, into
its **own namespace `whoami-flux`** — so the two GitOps engines never fight over
the same objects. Adds a `podinfo` HelmRelease to exercise the Helm path too.

Repo is on GitLab (`gitlab.com/__GITLAB_PROJECT__`); Flux is git-host
agnostic (`GitRepository` takes any URL; `flux bootstrap` has a `gitlab` provider).

## Layout

```
flux/
├── sources/
│   ├── gitrepository.yaml    # GitRepository: this repo, branch main, 1m poll
│   └── helmrepository.yaml   # HelmRepository: podinfo chart repo
├── kustomizations/
│   └── whoami.yaml           # Kustomization: reconcile ./apps/whoami -> whoami-flux ns
├── helmreleases/
│   └── podinfo.yaml          # HelmRelease: podinfo -> flux-demo ns
└── apps/whoami/              # Flux-only kustomize overlay (reuses ../../apps/whoami/base)
    ├── kustomization.yaml    #   namespace: whoami-flux, replicas 1, NO ALB ingress
    └── namespace.yaml
```

## Argo → Flux mental-model map (the interview-useful part)

| Concept | ArgoCD | Flux v2 |
|---|---|---|
| What is Git source | `Application.spec.source` (repoURL+path) | **`GitRepository`** CR (source-controller) |
| What renders manifests | Argo's built-in kustomize/helm | **`Kustomization`** CR (kustomize-controller) / **`HelmRelease`** (helm-controller) |
| Fan-out over many targets | `ApplicationSet` (git/cluster generators) | multiple `Kustomization`s, or one `Kustomization` per dir; no built-in generator — you template/compose |
| Auto-sync | `syncPolicy.automated` | `Kustomization` reconciles on `interval` (there is no "manual sync mode" — you `suspend`) |
| Self-heal / drift correction | `selfHeal: true` | always on; `spec.force`/SSA reconcile; `suspend` to pause |
| Prune deleted objects | `prune: true` | `prune: true` (needs inventory → `Kustomization`, not raw source) |
| Wait for health | Argo health assessment | `wait: true` + `timeout` (kstatus-based) |
| Install itself | Argo installed via Helm/manifests | `flux install` **or** `flux bootstrap <provider>` (Flux manages Flux via Git) |
| UI | first-class web UI | CLI-first (`flux get ...`); optional Weave GUI |
| Namespaced ownership | `Application` in `argocd` ns → any dest | Flux CRs live in `flux-system`; `targetNamespace` sets dest |

Key difference to say out loud: **Argo is application-centric with a strong UI and
ApplicationSet generators; Flux is a set of composable controllers (source / kustomize /
helm / notification / image) that you wire together — more Unix-y, GitOps-Toolkit style.**

## Apply runbook (run when the cluster is reachable)

> Cluster access is currently blocked (AssumeRole to `eks-practice-nonprod-eks-admin`
> denied). Restore kube access first, then:

### Option A — quick (imperative install, declarative apps)
```bash
flux check --pre                                  # verify cluster prereqs
flux install                                      # installs controllers into flux-system
kubectl apply -f v2/gitops/flux/sources/
kubectl apply -f v2/gitops/flux/kustomizations/
kubectl apply -f v2/gitops/flux/helmreleases/
```

### Option B — bootstrap (Flux manages Flux from Git, the production shape)
```bash
export GITLAB_TOKEN=<pat-with-api-scope>
flux bootstrap gitlab \
  --owner=__GITLAB_OWNER__ --repository=eks-practice \
  --branch=main --path=v2/gitops/flux --token-auth
# then commit the sources/kustomizations/helmreleases (already in this dir)
```

## Day-2 ops (what you demo / talk about)
```bash
flux get sources git                      # is the repo synced? last revision?
flux get kustomizations                    # reconcile status per Kustomization
flux get helmreleases -A                    # helm release status
flux reconcile kustomization whoami --with-source   # force a sync now
flux suspend kustomization whoami          # pause reconcile (change freeze)
flux resume  kustomization whoami
flux tree kustomization whoami             # show the objects Flux owns
kubectl -n whoami-flux get deploy,po,pdb,netpol,vpa   # verify the delivered app
# drift test: kubectl -n whoami-flux scale deploy/whoami --replicas=3
#   -> Flux reverts to 1 on next interval (or `flux reconcile` to see it immediately)
```

## Cleanup
```bash
kubectl delete -f v2/gitops/flux/helmreleases/ -f v2/gitops/flux/kustomizations/ -f v2/gitops/flux/sources/
flux uninstall     # if installed via Option A
```

## Offline validation done so far
- `kubectl kustomize v2/gitops/flux/apps/whoami` → 9 objects, all in `whoami-flux`.
- Flux CRs generated with `flux create ... --export` (schema-correct by construction).
