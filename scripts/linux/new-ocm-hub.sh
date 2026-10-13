#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

name="${1:-ocm-hub}"
context="k3d-$name"
image="${K3S_IMAGE:-rancher/k3s:v1.34.12-k3s1}"
require_commands k3d kubectl clusteradm jq

clusters="$(k3d cluster list -o json)"
if ! jq -e --arg name "$name" 'any(.[]?; .name == $name)' <<<"$clusters" >/dev/null; then
  k3d cluster create "$name" --image "$image" --wait --timeout 5m
fi
check_context "$context"
if kubectl --context "$context" get clustermanager cluster-manager >/dev/null 2>&1; then
  printf 'OCM is already initialized on %s.\n' "$context"
  exit 0
fi
clusteradm init --wait --context "$context"
printf 'OCM hub is ready on %s.\n' "$context"
