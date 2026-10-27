#!/usr/bin/env bash
###
# One-shot rebuild of eks-practice-nonprod.
# Applies the AWS layers bottom-up (network -> cluster -> gitops). Bootstrap
# (state bucket + cross-account DNS role) is assumed to already exist and is NOT
# touched. After the 3 layers, ArgoCD is bootstrapped and auto-syncs every addon
# and app from git (~15-20 min) -- no further terraform needed.
#
# Usage:  AWS_PROFILE=k8s-sub ./apply-all.sh
###
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-k8s-sub}
cd "$(dirname "$0")"                     # v2/
ENVDIR=envs/nonprod

for layer in network cluster gitops; do
  echo
  echo "==================== terraform apply: $layer ===================="
  terraform -chdir="$ENVDIR/$layer" init  -input=false
  terraform -chdir="$ENVDIR/$layer" apply -input=false -auto-approve
done

echo
echo "==================== AWS layers applied ===================="
echo "ArgoCD is bootstrapped; it now syncs all addons + apps from git (~15-20 min)."
echo "Watch:  kubectl get applications -n argocd -w"
