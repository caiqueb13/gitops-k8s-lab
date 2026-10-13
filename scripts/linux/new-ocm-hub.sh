#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

name="${1:-ocm-hub}"
context="k3d-$name"
image="${K3S_IMAGE:-rancher/k3s:v1.34.12-k3s1}"
require_commands k3d kubectl clusteradm docker jq

clusters="$(k3d cluster list -o json)"
if ! jq -e --arg name "$name" 'any(.[]?; .name == $name)' <<<"$clusters" >/dev/null; then
  k3d cluster create "$name" --image "$image" --wait --timeout 5m
fi
check_context "$context"
if kubectl --context "$context" get crd clustermanagers.operator.open-cluster-management.io --ignore-not-found -o name | grep -q .; then
  printf 'OCM is already initialized on %s.\n' "$context"
  exit 0
fi
if ! clusteradm init --bundle-version v1.3.1 --wait --context "$context"; then
  require_commands helm
  printf 'clusteradm init could not render its embedded chart; falling back to the official OCM Helm chart v1.3.1.\n' >&2
  helm repo add ocm https://open-cluster-management.io/helm-charts --force-update
  helm repo update ocm
  helm upgrade --install cluster-manager ocm/cluster-manager --version 1.3.1 --kube-context "$context" --namespace open-cluster-management --create-namespace --set createBootstrapSA=true --set images.tag=v1.3.1 --wait --timeout 5m
fi
printf 'OCM hub is ready on %s.\n' "$context"
