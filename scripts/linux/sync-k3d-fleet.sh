#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

git_url="${1:-}"
hub_context="${HUB_CONTEXT:-k3d-ocm-hub}"
context_regex="${CONTEXT_PATTERN:-^k3d-}"
git_secret="${GIT_SECRET_NAME:-}"
[[ "$git_url" == https://* ]] || { printf 'Usage: %s HTTPS_GIT_URL\n' "$0" >&2; exit 2; }
require_commands k3d kubectl flux clusteradm jq
clusters="$(k3d cluster list -o json)"
mapfile -t names < <(jq -r '.[].name // empty' <<<"$clusters")
declare -A active=()
failures=0
for name in "${names[@]}"; do
  context="k3d-$name"
  [[ "$context" =~ $context_regex ]] || continue
  active["$name"]=1
  printf '\n=== %s ===\n' "$context"
  if bootstrap_context "$context" "$name" "$git_url" "$git_secret" && register_ocm_cluster "$context" "$name" "$hub_context" k3d-fleet; then
    :
  else
    printf 'Failed to reconcile %s; continuing with remaining clusters.\n' "$context" >&2
    ((failures+=1))
  fi
done

managed="$(kubectl --context "$hub_context" get managedclusters -l lab.gitops/managed-by=k3d-fleet -o json)"
for stale in $(jq -r '.items[].metadata.name' <<<"$managed"); do
  [[ -n "${active[$stale]:-}" ]] && continue
  printf 'Removing deleted k3d cluster %s from OCM inventory.\n' "$stale"
  kubectl --context "$hub_context" delete managedcluster "$stale" --wait=false
done

printf 'Fleet scan completed with %d failure(s).\n' "$failures"
((failures == 0))
