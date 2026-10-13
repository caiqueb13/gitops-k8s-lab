#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

git_url="${1:-}"
context_regex="${CONTEXT_PATTERN:-^k3d-}"
git_secret="${GIT_SECRET_NAME:-}"
[[ "$git_url" == https://* ]] || { printf 'Usage: %s HTTPS_GIT_URL\n' "$0" >&2; exit 2; }
require_commands k3d kubectl flux jq
clusters="$(k3d cluster list -o json)"
mapfile -t names < <(jq -r '.[].name // empty' <<<"$clusters")
failures=0
for name in "${names[@]}"; do
  context="k3d-$name"
  [[ "$context" =~ $context_regex ]] || continue
  printf '\n=== %s ===\n' "$context"
  if bootstrap_context "$context" "$name" "$git_url" "$git_secret"; then
    :
  else
    printf 'Failed to reconcile %s; continuing with remaining clusters.\n' "$context" >&2
    ((failures+=1))
  fi
done

printf 'Fleet scan completed with %d failure(s). Active k3d clusters are discovered directly by the dashboard.\n' "$failures"
((failures == 0))
