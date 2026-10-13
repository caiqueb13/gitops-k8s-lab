#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
obs_dir="$repo_root/observability"
pid_file="$obs_dir/.state/collector.pid"
if [[ -f "$pid_file" ]]; then
  collector_pid="$(cat "$pid_file")"
  if ps -p "$collector_pid" -o args= | grep -Fq 'observability/collector.py'; then
    kill "$collector_pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
fi
(cd "$obs_dir" && docker compose down)
printf 'Grafana and Prometheus stopped. Historical metrics remain in Docker volumes.\n'
