#!/usr/bin/env bash
set -Eeuo pipefail
scenario_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$scenario_dir/.." && pwd)"
source "$repo_root/scripts/linux/lib.sh"
flux_name="${FLUX_CLUSTER_NAME:-demo-gitops}"
plain_name="${PLAIN_CLUSTER_NAME:-demo-plain}"
git_url="${GIT_URL:-https://github.com/caiqueb13/gitops-k8s-lab.git}"
k3s_image="${K3S_IMAGE:-rancher/k3s:v1.34.12-k3s1}"
action="${1:-setup}"
[[ "$flux_name" != "$plain_name" ]] || { printf 'Demo cluster names must differ.\n' >&2; exit 2; }
require_commands k3d kubectl flux jq

if [[ "$action" == cleanup ]]; then
  for name in "$flux_name" "$plain_name"; do
    if k3d cluster list -o json | jq -e --arg name "$name" 'any(.[]?; .name == $name)' >/dev/null; then
      k3d cluster delete "$name"
    fi
  done
  exit 0
fi
[[ "$action" == setup ]] || { printf 'Usage: %s [setup|cleanup]\n' "$0" >&2; exit 2; }

for name in "$flux_name" "$plain_name"; do
  if ! k3d cluster list -o json | jq -e --arg name "$name" 'any(.[]?; .name == $name)' >/dev/null; then
    k3d cluster create "$name" --image "$k3s_image" --wait --timeout 5m
  fi
  check_context "k3d-$name"
done
bootstrap_context "k3d-$flux_name" "$flux_name" "$git_url"
printf 'Demo ready. Compare k3d-%s (Flux/GitOps) with k3d-%s (no Flux/Kyverno) in Grafana.\n' "$flux_name" "$plain_name"
printf 'Remove only these clusters with: %s cleanup\n' "$0"
