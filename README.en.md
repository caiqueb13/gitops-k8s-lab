# Multi-cluster GitOps lab: k3d, Flux, Helm, Kyverno, and Grafana

A local lab for creating Kubernetes clusters with k3d/K3s, configuring Flux, and viewing cluster state, Helm charts, and Kyverno policy activity in Grafana. The open-source stack runs locally; it creates no cloud infrastructure and does not use OCM.

## How observability works

- A Python collector runs on the host and queries configured contexts with `kubectl` and `helm`, using the existing kubeconfig. It does not copy kubeconfigs or Secret values into the repository or Grafana.
- Prometheus stores metrics locally for 15 days by default (configurable); Grafana serves the `GitOps Lab / Fleet Compliance` dashboard.
- Active k3d clusters are discovered automatically. Non-k3d contexts are included only when listed in `observability/contexts.txt` or `OBSERVABILITY_CONTEXTS`.
- The collector is read-only. Grafana and Prometheus web endpoints bind to `localhost`; port `9797` must accept Docker container connections and should be restricted by the host firewall.
- OCM and `clusteradm` have been removed from lab workflows. Dashboard inventory comes from active k3d clusters and explicitly included contexts.

The dashboard shows Helm releases and chart versions, Flux controller and Kustomization/HelmRelease health, applied Git revisions, Kyverno presence/health, policies and current PolicyReport failures, admission denial and policy failure metrics, controller versions, deployment status, pod restarts, and CPU/memory reported by `kubectl top`.

The current repository installs Kyverno but does not yet define sample Kyverno policies. Policy counts and violations will be zero/empty until policies are installed on a cluster.

## Status meanings and data limits

- **Kyverno:** `installed_healthy` requires Kyverno CRDs and available admission, background, and reports controllers. `not_installed` means no Kyverno CRDs or deployments were found. A detected installation that does not pass the health check appears as `partial_or_unhealthy`.
- **Flux in sync:** compares each `Kustomization.status.lastAppliedRevision` with the artifact published by that cluster's `GitRepository`. It does not query GitHub's remote HEAD; if Flux has not fetched the newest commit, the comparison is against its latest fetched revision.
- **Kyverno Audit:** admission metric failures and PolicyReports identify resources that passed validation in Audit mode. PolicyReports represent current resource state, not an event history.
- **Kyverno Enforce:** policy failure metrics show failed evaluations; the denied admission request metric counts requests rejected by Kyverno, which can also include webhook errors. Historical data starts when Prometheus begins scraping.
- **Charts:** `helm list -A` reports Helm releases visible to the local user. Applications installed without Helm are not chart releases.
- **CPU and memory:** current `kubectl top` values depend on the cluster Metrics Server. No historical data is reconstructed.

## Prerequisites

- Docker Desktop/Engine and Docker Compose v2.
- Python 3, `kubectl`, Helm 3+, and k3d. The Flux CLI is needed for bootstrap and manual inspection.
- Ubuntu: `jq` for Bash provisioning scripts.
- Git repository reachable from clusters. For a private repository, the Git authentication Secret must already exist in each cluster's `flux-system` namespace before onboarding.

Check tools on Windows:

```powershell
Get-Command docker, k3d, kubectl, helm, flux, python
docker info
```

On Ubuntu:

```bash
command -v docker k3d kubectl helm flux python3 jq
docker info
```

## Start the dashboard

From the repository root on Windows:

```powershell
./scripts/start-dashboard.ps1
```

On Ubuntu:

```bash
bash scripts/linux/start-dashboard.sh
```

The script starts the collector and Prometheus/Grafana containers, then opens `http://localhost:3000`. Initial login: `admin` / `admin`; change the password at first login. Open **GitOps Lab → Fleet Compliance**. Docker volumes retain data after the containers stop.

To start without opening a browser, use `./scripts/start-dashboard.ps1 -NoBrowser` or `bash scripts/linux/start-dashboard.sh --no-browser`.

Stop the dashboard:

```powershell
./scripts/stop-dashboard.ps1
```

```bash
bash scripts/linux/stop-dashboard.sh
```

This preserves Prometheus history. To also delete the history and Grafana data, deliberately run `docker compose -f observability/docker-compose.yml down -v`.

## Create and discover clusters

Create a test cluster with Flux and Kyverno delivered by GitOps:

```powershell
$GitUrl = 'https://github.com/caiqueb13/gitops-k8s-lab.git'
./scripts/new-k3d-cluster.ps1 -Name aks-sim -GitUrl $GitUrl
```

```bash
GitUrl='https://github.com/caiqueb13/gitops-k8s-lab.git'
bash scripts/linux/new-k3d-cluster.sh aks-sim "$GitUrl"
```

To onboard all active k3d clusters matching `k3d-*`, run a one-time scan:

```powershell
./scripts/sync-k3d-fleet.ps1 -GitUrl $GitUrl
```

```bash
bash scripts/linux/sync-k3d-fleet.sh "$GitUrl"
```

The watcher repeats bootstrap periodically while running: `./scripts/watch-k3d-fleet.ps1 -GitUrl $GitUrl` on Windows, or `bash scripts/linux/watch-k3d-fleet.sh "$GitUrl"` on Ubuntu. The dashboard discovers k3d clusters independently of the watcher. A deleted cluster disappears after the next collector refresh.

To onboard an existing non-k3d context, select it explicitly:

```powershell
./scripts/onboard-existing-context.ps1 -Context aks-dev -GitUrl $GitUrl
Add-Content observability/contexts.txt 'aks-dev'
```

```bash
bash scripts/linux/onboard-existing-context.sh --context aks-dev --git-url "$GitUrl"
echo aks-dev >> observability/contexts.txt
```

`observability/contexts.txt` is Git-ignored. Remove a line when that context should no longer be queried. Alternatively, set `OBSERVABILITY_CONTEXTS` to comma-separated names when starting the collector.

For a private repository, pass `-GitSecretName secret-name` in PowerShell or `--git-secret secret-name` in Bash. The script only references a Secret that already exists on the cluster; it never accepts or writes credential values.

## Comparison demo

Create two clusters, one with Flux/Kyverno and one without, then compare their states in Grafana:

```powershell
./Scenarios/gitops-observability-demo.ps1 -GitUrl $GitUrl
```

```bash
GIT_URL="$GitUrl" bash Scenarios/gitops-observability-demo.sh
```

The scenario does not delete pre-existing clusters. To delete only the two demo clusters, run `./Scenarios/gitops-observability-demo.ps1 -Cleanup` or `bash Scenarios/gitops-observability-demo.sh cleanup`.

## Access and inspect components manually

```powershell
kubectl --context k3d-aks-sim get nodes
helm list -A --kube-context k3d-aks-sim
flux get all -A --context k3d-aks-sim
kubectl --context k3d-aks-sim get deployments -n kyverno
kubectl --context k3d-aks-sim get clusterpolicies,policies -A
kubectl --context k3d-aks-sim get policyreports.wgpolicyk8s.io,clusterpolicyreports.wgpolicyk8s.io -A
```

The same commands work in an Ubuntu shell. Check the collector at `http://localhost:9797/healthz` and Prometheus at `http://localhost:9090`.

## Delete local clusters

Delete clusters you no longer need individually:

```powershell
k3d cluster delete aks-sim
```

```bash
k3d cluster delete aks-sim
```

Old OCM demo clusters, if they still exist (`ocm-hub`, `ocm-flux-demo`, `ocm-plain-demo`), are not removed automatically by updating the repository. Delete them explicitly with `k3d cluster delete <name>` after confirming they contain no data you need.

## Future scope

This implementation collects local clusters and explicitly configured Kubernetes contexts; it does not automatically discover Azure, AWS, or Google Cloud inventories. In production, a per-cluster agent/collector with minimal RBAC and authenticated metric shipping to a central platform avoids distributing administrative kubeconfigs. Provider inventory integration, corporate identity, and authenticated comparison with GitHub's remote HEAD are outside this lab.
