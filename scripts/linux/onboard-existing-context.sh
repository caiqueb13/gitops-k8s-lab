#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() { printf 'Usage: %s --context CONTEXT --git-url HTTPS_URL [--cluster-name NAME] [--git-secret NAME]\n' "$0"; }
context='' git_url='' cluster_name='' git_secret=''
while (($#)); do
  case "$1" in
    --context) context="${2:?missing context}"; shift 2 ;;
    --git-url) git_url="${2:?missing Git URL}"; shift 2 ;;
    --cluster-name) cluster_name="${2:?missing cluster name}"; shift 2 ;;
    --git-secret) git_secret="${2:?missing Secret name}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$context" && "$git_url" == https://* ]] || { usage >&2; exit 2; }
if [[ -z "$cluster_name" ]]; then
  cluster_name="$(tr '[:upper:]' '[:lower:]' <<<"$context" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+|-+$//g' | cut -c1-50 | sed -E 's/-+$//')"
fi
[[ "$cluster_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { printf 'Invalid cluster name: %s\n' "$cluster_name" >&2; exit 2; }
if [[ -n "$git_secret" ]]; then
  [[ "$git_secret" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { printf 'Invalid Secret name.\n' >&2; exit 2; }
fi

bootstrap_context "$context" "$cluster_name" "$git_url" "$git_secret"
printf 'Onboarding complete for %s. Add its exact context to observability/contexts.txt to include it in Grafana.\n' "$context"
