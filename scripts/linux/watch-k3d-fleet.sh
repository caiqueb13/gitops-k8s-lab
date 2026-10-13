#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

git_url="${1:-}"
interval="${INTERVAL_SECONDS:-60}"
[[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 15 && "$interval" -le 3600 ]] || { printf 'INTERVAL_SECONDS must be 15..3600.\n' >&2; exit 2; }
[[ "$git_url" == https://* ]] || { printf 'Usage: %s HTTPS_GIT_URL\n' "$0" >&2; exit 2; }
printf 'Watching k3d fleet every %s seconds. Press Ctrl+C to stop.\n' "$interval"
while true; do
  if ! "$LAB_SCRIPTS_DIR/sync-k3d-fleet.sh" "$git_url"; then
    printf 'Fleet sync failed; retrying after interval.\n' >&2
  fi
  sleep "$interval"
done
