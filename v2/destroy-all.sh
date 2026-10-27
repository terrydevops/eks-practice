#!/usr/bin/env bash
###
# One-shot teardown of eks-practice-nonprod.
#
# `terraform destroy` alone LEAKS the resources that GitOps controllers create
# outside TF state -- ALBs (from Ingress), EBS volumes (from PVC), Karpenter EC2
# nodes -- and then VPC destroy fails on the leftover ENIs. So this script FIRST
# deletes those via kubectl (while the controllers are still alive), THEN destroys
# the AWS layers top-down (gitops -> cluster -> network).
#
# Bootstrap (state bucket + DNS role) and the CI layer are KEPT, so `apply-all.sh`
# can rebuild in one shot. Orphaned Route53 records (external-dns is upsert-only)
# are left behind -- they cost nothing and get re-upserted on rebuild.
#
# Usage:  AWS_PROFILE=k8s-sub ./destroy-all.sh
###
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-k8s-sub}
REGION=${REGION:-ap-southeast-2}
cd "$(dirname "$0")"                     # v2/
ENVDIR=envs/nonprod

echo "This DESTROYS eks-practice-nonprod: gitops + cluster + network layers,"
echo "and cleans the controller-managed ALBs / EBS volumes / Karpenter nodes."
echo "KEPT: bootstrap (state bucket + DNS role) and the ci layer."
read -rp "Type 'destroy' to continue: " ans
[ "$ans" = "destroy" ] || { echo "aborted."; exit 1; }

# 1) Clean controller-managed AWS resources while the cluster is still reachable.
if kubectl cluster-info >/dev/null 2>&1; then
  echo "== stopping ArgoCD auto-sync so it doesn't recreate what we delete =="
  for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do
    kubectl -n argocd patch "$app" --type=json \
      -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true
  done

  echo "== deleting Ingresses (LB controller deletes the ALBs via finalizer) =="
  kubectl delete ingress --all -A --ignore-not-found --timeout=180s || true

  # The wildcard ACM cert (cluster layer) is attached to these ALBs; ACM refuses
  # to be destroyed while in use, so the cluster-layer destroy would fail. Block
  # until every k8s-* ALB is actually gone before we get there.
  echo "== waiting for all ALBs to be deleted (ACM cert is in use until then) =="
  for i in $(seq 1 36); do
    n=$(aws elbv2 describe-load-balancers --region "$REGION" \
          --query "length(LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')])" \
          --output text 2>/dev/null || echo "?")
    [ "$n" = "0" ] && { echo "   all ALBs gone."; break; }
    echo "   $n ALB(s) still present, waiting... ($i/36)"; sleep 10
  done

  echo "== deleting PVCs (EBS CSI deletes the volumes) =="
  kubectl delete pvc --all -A --ignore-not-found --timeout=120s || true

  echo "== deleting Karpenter NodePools (drains any Karpenter nodes) =="
  kubectl delete nodepools.karpenter.sh --all --ignore-not-found --timeout=120s || true
else
  echo "== cluster not reachable; skipping in-cluster cleanup =="
fi

# 2) Destroy the AWS layers top-down. gitops first (needs the cluster alive to
#    talk to ArgoCD), then cluster (EKS + node group + addon IAM + ACM), then
#    network (VPC -- now free of ALB/node ENIs).
for layer in gitops cluster network; do
  echo
  echo "==================== terraform destroy: $layer ===================="
  terraform -chdir="$ENVDIR/$layer" init    -input=false
  terraform -chdir="$ENVDIR/$layer" destroy -input=false -auto-approve
done

echo
echo "==================== teardown complete ===================="
echo "Bootstrap + ci kept. Rebuild any time with:  AWS_PROFILE=$AWS_PROFILE ./apply-all.sh"
