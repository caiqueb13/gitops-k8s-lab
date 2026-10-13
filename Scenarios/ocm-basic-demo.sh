#!/usr/bin/env bash
set -Eeuo pipefail

scenario_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$scenario_dir/.." && pwd)"
source "$repo_root/scripts/linux/lib.sh"

hub_name="${HUB_CLUSTER_NAME:-ocm-hub}"
flux_name="${FLUX_CLUSTER_NAME:-ocm-flux-demo}"
plain_name="${PLAIN_CLUSTER_NAME:-ocm-plain-demo}"
git_url="${GIT_URL:-https://github.com/caiqueb13/gitops-k8s-lab.git}"
k3s_image="${K3S_IMAGE:-rancher/k3s:v1.34.12-k3s1}"
hub_context="k3d-$hub_name"
flux_context="k3d-$flux_name"
plain_context="k3d-$plain_name"
shared_network="k3d-$hub_name"

for name in "$hub_name" "$flux_name" "$plain_name"; do
  [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { printf 'Invalid k3d cluster name: %s\n' "$name" >&2; exit 2; }
done
[[ "$hub_name" != "$flux_name" && "$hub_name" != "$plain_name" && "$flux_name" != "$plain_name" ]] || {
  printf 'Hub, Flux demo, and plain demo cluster names must be different.\n' >&2
  exit 2
}
require_commands k3d kubectl clusteradm docker flux jq

printf 'Preparing the OCM hub...\n'
K3S_IMAGE="$k3s_image" bash "$repo_root/scripts/linux/new-ocm-hub.sh" "$hub_name"
docker network inspect "$shared_network" >/dev/null

ensure_spoke() {
  local name="$1" context="k3d-$1" clusters networks
  clusters="$(k3d cluster list -o json)"
  if ! jq -e --arg name "$name" 'any(.[]?; .name == $name)' <<<"$clusters" >/dev/null; then
    printf 'Creating %s on shared Docker network %s...\n' "$name" "$shared_network"
    k3d cluster create "$name" --image "$k3s_image" --network "$shared_network" --wait --timeout 5m
  fi
  check_context "$context"
  networks="$(docker inspect "k3d-$name-server-0" --format '{{json .NetworkSettings.Networks}}')"
  jq -e --arg network "$shared_network" 'has($network)' <<<"$networks" >/dev/null || {
    printf 'Cluster %s is not attached to %s. Delete only that demo cluster and rerun.\n' "$name" "$shared_network" >&2
    return 1
  }
}

ensure_spoke "$flux_name"
ensure_spoke "$plain_name"

printf 'Installing Flux and reconciling Kyverno from %s on %s...\n' "$git_url" "$flux_name"
bootstrap_context "$flux_context" "$flux_name" "$git_url"

printf 'Registering both spokes with OCM...\n'
register_ocm_cluster "$flux_context" "$flux_name" "$hub_context" ocm-demo
register_ocm_cluster "$plain_context" "$plain_name" "$hub_context" ocm-demo

printf '\nManaged clusters visible to OCM on %s:\n' "$hub_context"
kubectl --context "$hub_context" get managedclusters
printf '\nManagedCluster details:\n'
kubectl --context "$hub_context" get managedcluster "$flux_name" "$plain_name" -o wide

printf '\nFlux and Kyverno on %s (expected present and healthy):\n' "$flux_name"
flux get all -A --context "$flux_context"
kubectl --context "$flux_context" -n flux-system get helmrelease kyverno

printf '\nFlux and Kyverno on %s (expected absent):\n' "$plain_name"
kubectl --context "$plain_context" get namespaces flux-system kyverno --ignore-not-found
printf '\nOCM tracks both clusters; only %s receives Flux and Kyverno.\n' "$flux_name"
