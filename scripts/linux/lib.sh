#!/usr/bin/env bash
set -Eeuo pipefail

LAB_SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_REPO_ROOT="$(cd -- "$LAB_SCRIPTS_DIR/../.." && pwd)"

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf 'Required command not found: %s\n' "$command_name" >&2
      return 1
    }
  done
}

check_context() {
  local context="$1"
  kubectl --context "$context" cluster-info >/dev/null
}

bootstrap_context() {
  local context="$1" name="$2" git_url="$3" secret_name="${4:-}"
  local template rendered controllers count existing_url existing_secret existing_path existing_source
  template="$LAB_REPO_ROOT/bootstrap/flux-sync.yaml.template"
  [[ -f "$template" ]] || { printf 'Flux bootstrap template is missing: %s\n' "$template" >&2; return 1; }
  require_commands kubectl flux jq
  check_context "$context"

  controllers="$(kubectl --context "$context" -n flux-system get deployments source-controller kustomize-controller helm-controller notification-controller --ignore-not-found -o name)"
  count="$(printf '%s\n' "$controllers" | awk 'NF {n++} END {print n+0}')"
  if [[ "$count" -eq 0 ]]; then
    flux check --pre --context "$context"
    flux install --context "$context"
  elif [[ "$count" -lt 4 ]]; then
    printf 'Flux is partially installed in %s (%s/4 controllers); refusing to overwrite it.\n' "$context" "$count" >&2
    return 1
  else
    flux check --context "$context"
  fi
  if [[ -n "$secret_name" ]]; then
    kubectl --context "$context" -n flux-system get secret "$secret_name" >/dev/null || {
      printf 'Git auth Secret %s must already exist in flux-system; this script never accepts or stores secret values.\n' "$secret_name" >&2
      return 1
    }
  fi

  if existing_url="$(kubectl --context "$context" -n flux-system get gitrepository lab-config --ignore-not-found -o json 2>/dev/null)" && [[ -n "$existing_url" ]]; then
    existing_secret="$(jq -r '.spec.secretRef.name // ""' <<<"$existing_url")"
    existing_url="$(jq -r '.spec.url // ""' <<<"$existing_url")"
    if [[ "$existing_url" != "$git_url" || "$existing_secret" != "$secret_name" ]]; then
      printf 'GitRepository/lab-config already exists in %s with a different URL or auth Secret. Resolve the ownership conflict first.\n' "$context" >&2
      return 1
    fi
  fi
  if existing_path="$(kubectl --context "$context" -n flux-system get kustomization kyverno --ignore-not-found -o json 2>/dev/null)" && [[ -n "$existing_path" ]]; then
    existing_source="$(jq -r '.spec.sourceRef.name // ""' <<<"$existing_path")"
    existing_path="$(jq -r '.spec.path // ""' <<<"$existing_path")"
    if [[ "$existing_path" != './apps/kyverno' || "$existing_source" != 'lab-config' ]]; then
      printf 'Kustomization/kyverno already exists in %s with a different path/source. Resolve the ownership conflict first.\n' "$context" >&2
      return 1
    fi
  fi

  rendered="$(mktemp)"
  trap 'rm -f -- "$rendered"' RETURN
  if [[ -n "$secret_name" ]]; then
    sed -e "s|__GIT_URL__|$git_url|g" -e "s|__GIT_SECRET_REF__|  secretRef:\n    name: $secret_name|g" "$template" >"$rendered"
  else
    sed -e "s|__GIT_URL__|$git_url|g" -e '/__GIT_SECRET_REF__/d' "$template" >"$rendered"
  fi
  if grep -q '__GIT_' "$rendered"; then
    printf 'Unrendered placeholder in Flux bootstrap manifest.\n' >&2
    return 1
  fi
  kubectl --context "$context" apply -f "$rendered"
  kubectl --context "$context" -n flux-system wait --for=condition=Ready kustomization/kyverno --timeout=5m
  kubectl --context "$context" -n flux-system wait --for=condition=Ready helmrelease/kyverno --timeout=10m
  rm -f -- "$rendered"
  trap - RETURN
}

register_ocm_cluster() {
  local context="$1" cluster_name="$2" hub_context="$3" managed_by="$4"
  local current joined token_output token api
  require_commands kubectl clusteradm
  kubectl --context "$hub_context" get clustermanager cluster-manager >/dev/null
  check_context "$context"
  current="$(kubectl --context "$hub_context" get managedcluster "$cluster_name" --ignore-not-found -o json)"
  joined="$(jq -r 'select(.spec.hubAcceptsClient == true) | [.status.conditions[]? | select(.type == "ManagedClusterJoined" and .status == "True")] | length' <<<"$current" 2>/dev/null || printf '0')"
  if [[ "$joined" != "1" ]]; then
    token_output="$(clusteradm get token --context "$hub_context" 2>&1)"
    token="$(sed -nE 's/.*--hub-token(=|[[:space:]]+)([^[:space:]]+).*/\2/p' <<<"$token_output" | head -n1)"
    api="$(sed -nE 's/.*--hub-apiserver(=|[[:space:]]+)([^[:space:]]+).*/\2/p' <<<"$token_output" | head -n1)"
    [[ -n "$token" && -n "$api" ]] || { printf 'Could not parse OCM token/API endpoint from clusteradm output.\n' >&2; return 1; }
    clusteradm join --hub-token "$token" --hub-apiserver "$api" --wait --cluster-name "$cluster_name" --force-internal-endpoint-lookup --context "$context"
    clusteradm accept --clusters "$cluster_name" --context "$hub_context"
  fi
  kubectl --context "$hub_context" label managedcluster "$cluster_name" "lab.gitops/managed-by=$managed_by" --overwrite
  kubectl --context "$hub_context" annotate managedcluster "$cluster_name" "lab.gitops/context=$context" --overwrite
}

resource_ready() {
  local context="$1" namespace="$2" resource="$3"
  kubectl --context "$context" -n "$namespace" get "$resource" -o json 2>/dev/null |
    jq -e '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0' >/dev/null
}

flux_controllers_ready() {
  local context="$1" deployment_json
  flux check --context "$context" >/dev/null 2>&1 || return 1
  deployment_json="$(kubectl --context "$context" -n flux-system get deployments source-controller kustomize-controller helm-controller notification-controller -o json 2>/dev/null)" || return 1
  jq -e '(.items | length == 4) and all(.items[]; ((.status.availableReplicas // 0) >= (.spec.replicas // 1)))' <<<"$deployment_json" >/dev/null
}
