#!/usr/bin/env bash
set -Eeuo pipefail

scenario_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$scenario_dir/.." && pwd)"
source "$repo_root/scripts/linux/lib.sh"

hub_name="${HUB_CLUSTER_NAME:-ocm-hub}"
spoke_name="${SPOKE_CLUSTER_NAME:-ocm-demo}"
k3s_image="${K3S_IMAGE:-rancher/k3s:v1.34.12-k3s1}"
hub_context="k3d-$hub_name"
spoke_context="k3d-$spoke_name"
shared_network="k3d-$hub_name"

for name in "$hub_name" "$spoke_name"; do
  [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || {
    printf 'Invalid k3d cluster name: %s\n' "$name" >&2
    exit 2
  }
done
require_commands k3d kubectl clusteradm docker jq

printf 'Preparing the OCM hub...\n'
bash "$repo_root/scripts/linux/new-ocm-hub.sh" "$hub_name"
docker network inspect "$shared_network" >/dev/null

clusters="$(k3d cluster list -o json)"
if ! jq -e --arg name "$spoke_name" 'any(.[]?; .name == $name)' <<<"$clusters" >/dev/null; then
  printf 'Creating demo spoke %s on shared Docker network %s...\n' "$spoke_name" "$shared_network"
  k3d cluster create "$spoke_name" --image "$k3s_image" --network "$shared_network" --wait --timeout 5m
fi

check_context "$hub_context"
check_context "$spoke_context"
spoke_networks="$(docker inspect "k3d-$spoke_name-server-0" --format '{{json .NetworkSettings.Networks}}')"
jq -e --arg network "$shared_network" 'has($network)' <<<"$spoke_networks" >/dev/null || {
  printf 'Demo cluster %s is not attached to %s. Delete only that demo cluster and rerun this script.\n' "$spoke_name" "$shared_network" >&2
  exit 1
}

printf 'Registering the demo spoke with OCM...\n'
register_ocm_cluster "$spoke_context" "$spoke_name" "$hub_context" ocm-demo

printf '\nManaged clusters visible to OCM on %s:\n' "$hub_context"
kubectl --context "$hub_context" get managedclusters
printf '\nDemo cluster details and registration conditions:\n'
kubectl --context "$hub_context" get managedcluster "$spoke_name" -o yaml
printf '\nThis demo installs OCM only; it does not install Flux or Kyverno on %s.\n' "$spoke_name"
