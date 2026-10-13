#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

name="${1:-}"
git_url="${2:-}"
git_secret="${GIT_SECRET_NAME:-}"
image="${K3S_IMAGE:-rancher/k3s:v1.34.12-k3s1}"
[[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && "$git_url" == https://* ]] || {
  printf 'Usage: %s CLUSTER_NAME HTTPS_GIT_URL\n' "$0" >&2
  exit 2
}
require_commands k3d kubectl flux jq
k3d cluster create "$name" --image "$image" --wait --timeout 5m
bootstrap_context "k3d-$name" "$name" "$git_url" "$git_secret"
printf 'Cluster k3d-%s is ready for monitoring. Start Grafana with scripts/linux/start-dashboard.sh.\n' "$name"
