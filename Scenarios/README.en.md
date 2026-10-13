# Demo: per-cluster GitOps visibility

This demo creates or reuses two local k3d clusters:

- `demo-gitops`: receives Flux and Kyverno through the bootstrap/GitOps flow.
- `demo-plain`: remains without Flux and Kyverno.

On Windows, run `./Scenarios/gitops-observability-demo.ps1 -GitUrl $GitUrl`; on Ubuntu, run `GIT_URL="$GitUrl" bash Scenarios/gitops-observability-demo.sh`. Start Grafana and compare the health states, inventory, and charts for both contexts.

Setup does not delete existing clusters. To remove only the demo clusters, use `-Cleanup` in PowerShell or the `cleanup` argument in Bash. Other kubeconfig entries and clusters are left alone.
