#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
obs_dir="$repo_root/observability"
state_dir="$obs_dir/.state"
mkdir -p "$state_dir"
for command_name in docker kubectl helm; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$command_name" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { printf 'Python 3 is required.\n' >&2; exit 1; }
docker compose version >/dev/null
pid_file="$state_dir/collector.pid"
if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null && ps -p "$(cat "$pid_file")" -o args= | grep -Fq 'observability/collector.py'; then
  printf 'Metrics collector already running (PID %s).\n' "$(cat "$pid_file")"
else
  export OBSERVABILITY_BIND=0.0.0.0
  nohup python3 "$obs_dir/collector.py" >"$state_dir/collector.log" 2>"$state_dir/collector-error.log" </dev/null &
  echo "$!" >"$pid_file"
  sleep 2
  if ! kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    rm -f "$pid_file"
    printf 'Metrics collector failed to start; inspect %s\n' "$state_dir/collector-error.log" >&2
    exit 1
  fi
fi
(cd "$obs_dir" && docker compose up -d)
printf 'Grafana dashboard: http://localhost:3000/d/gitops-lab-fleet/gitops-lab-fleet-compliance\n'
printf 'Default local login: admin / admin. Change it on first login.\n'
if [[ "${1:-}" != "--no-browser" ]]; then
  if command -v xdg-open >/dev/null 2>&1; then xdg-open 'http://localhost:3000/d/gitops-lab-fleet/gitops-lab-fleet-compliance' >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then open 'http://localhost:3000/d/gitops-lab-fleet/gitops-lab-fleet-compliance' >/dev/null 2>&1 &
  fi
fi
