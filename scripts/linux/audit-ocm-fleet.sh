#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
hub_context="${HUB_CONTEXT:-k3d-ocm-hub}"
format="${1:-table}"
fail_on_unhealthy="${FAIL_ON_UNHEALTHY:-false}"
require_commands kubectl flux jq
inventory="$(kubectl --context "$hub_context" get managedclusters -l lab.gitops/managed-by -o json)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
results='[]'
mapfile -t cluster_names < <(jq -r '.items[].metadata.name' <<<"$inventory")
for name in "${cluster_names[@]}"; do
  context="$(jq -r --arg name "$name" '.items[] | select(.metadata.name == $name) | .metadata.annotations["lab.gitops/context"] // ""' <<<"$inventory")"
  flux_state='NotReady' kyverno_state='NotReady' details=''
  if [[ -z "$context" ]] || ! check_context "$context" >/dev/null 2>&1; then
    details='context unavailable or missing'
  else
    if flux_controllers_ready "$context" && resource_ready "$context" flux-system gitrepository/lab-config && resource_ready "$context" flux-system kustomization/kyverno; then
      flux_state='Ready'
    else
      details='Flux controllers, source, or Kustomization not Ready'
    fi
    if resource_ready "$context" flux-system helmrelease/kyverno; then
      pods="$(kubectl --context "$context" -n kyverno get pods -o json 2>/dev/null || printf '{}')"
      if jq -e '.items | length > 0 and all(.[]; .status.phase == "Running")' <<<"$pods" >/dev/null; then
        kyverno_state='Ready'
      else
        details="${details:+$details; }Kyverno pods not Running"
      fi
    else
      details="${details:+$details; }Kyverno HelmRelease not Ready"
    fi
  fi
  cluster_json="$(jq -c --arg name "$name" '.items[] | select(.metadata.name == $name)' <<<"$inventory")"
  available="$(jq -r '[.status.conditions[]? | select(.type == "ManagedClusterConditionAvailable")][0].status // "Unknown"' <<<"$cluster_json")"
  kubectl --context "$hub_context" annotate managedcluster "$name" "lab.gitops/flux-status=$flux_state" "lab.gitops/kyverno-status=$kyverno_state" "lab.gitops/last-audited=$timestamp" --overwrite >/dev/null
  result="$(jq -cn --arg cluster "$name" --arg context "$context" --arg available "$available" --arg flux "$flux_state" --arg kyverno "$kyverno_state" --arg details "$details" --arg audited "$timestamp" '{cluster:$cluster,context:$context,ocmAvailable:$available,flux:$flux,kyverno:$kyverno,details:$details,auditedAtUtc:$audited}')"
  results="$(jq -c --argjson row "$result" '. + [$row]' <<<"$results")"
done
case "$format" in
  json) jq . <<<"$results" ;;
  csv) jq -r '(["cluster","context","ocmAvailable","flux","kyverno","details","auditedAtUtc"] | @csv), (.[] | [.cluster,.context,.ocmAvailable,.flux,.kyverno,.details,.auditedAtUtc] | @csv)' <<<"$results" ;;
  table)
    printf '%-24s %-28s %-12s %-10s %-10s %s\n' Cluster Context OCM Flux Kyverno Details
    while IFS=$'\t' read -r cluster context available flux_state kyverno_state details; do
      printf '%-24s %-28s %-12s %-10s %-10s %s\n' "$cluster" "$context" "$available" "$flux_state" "$kyverno_state" "$details"
    done < <(jq -r '.[] | [.cluster,.context,.ocmAvailable,.flux,.kyverno,.details] | @tsv' <<<"$results")
    ;;
  *) printf 'Format must be table, json, or csv.\n' >&2; exit 2 ;;
esac
if [[ "$fail_on_unhealthy" == true ]] && ! jq -e 'all(.[]; .ocmAvailable == "True" and .flux == "Ready" and .kyverno == "Ready")' <<<"$results" >/dev/null; then
  exit 2
fi
