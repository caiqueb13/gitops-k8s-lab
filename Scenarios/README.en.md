# Scenario: OCM with and without GitOps

This demo creates or reuses an OCM hub (`ocm-hub`) and two managed K3s clusters:

- `ocm-flux-demo`: receives Flux and Kyverno from the public Git repository configured for this lab.
- `ocm-plain-demo`: is registered with OCM without Flux or Kyverno.

This lets you compare OCM inventory visibility with each cluster's GitOps state. OCM records and manages cluster membership; it does not install Flux on the plain cluster. The Flux cluster uses the existing bootstrap flow and waits for the `kyverno` HelmRelease to become healthy. The default repository is public, so this demo does not create or consume Git credentials.

## Windows

Requirements: Docker running, with `k3d`, `kubectl`, `clusteradm`, `flux`, and `helm` available on `PATH`.

```powershell
./Scenarios/ocm-basic-demo.ps1
```

Customize names, URL, or K3s image:

```powershell
./Scenarios/ocm-basic-demo.ps1 -HubName ocm-hub -FluxClusterName ocm-flux-demo -PlainClusterName ocm-plain-demo -GitUrl https://github.com/caiqueb13/gitops-k8s-lab.git
```

## Ubuntu / Linux

Requirements: Docker, `k3d`, `kubectl`, `clusteradm`, `flux`, `helm`, and `jq`.

```bash
bash Scenarios/ocm-basic-demo.sh
```

Customize with environment variables:

```bash
HUB_CLUSTER_NAME=ocm-hub FLUX_CLUSTER_NAME=ocm-flux-demo PLAIN_CLUSTER_NAME=ocm-plain-demo GIT_URL=https://github.com/caiqueb13/gitops-k8s-lab.git bash Scenarios/ocm-basic-demo.sh
```

Both spokes attach to the hub's Docker network so their OCM agents can reach the hub API. The scripts verify this connection. Existing clusters with the default names are reused; a cluster on another network causes an error to prevent silent changes.

The flow first tries to initialize and register clusters with `clusteradm`. If the installed version cannot render its embedded charts, it uses the official `cluster-manager` and `klusterlet` Helm charts v1.3.1. The local temporary file containing bootstrap configuration is removed after installation. OCM keeps an `open-cluster-management-agent/bootstrap-hub-kubeconfig` Secret on each spoke for registration communication; this token does not authenticate Flux to Git. This demo creates no Git credentials.

## What to observe

On the hub, `kubectl --context k3d-ocm-hub get managedclusters` lists both clusters. The details table shows conditions reported by each spoke. On `ocm-flux-demo`, `flux get all -A` and `kubectl -n flux-system get helmrelease kyverno` show GitOps reconciliation and healthy Kyverno. On `ocm-plain-demo`, the `flux-system` and `kyverno` namespaces are absent.

## Stop and clean up

If you do not need to keep the clusters for other scenarios, remove their hub registrations first, then delete all three clusters:

```powershell
kubectl --context k3d-ocm-hub delete managedcluster ocm-flux-demo ocm-plain-demo --wait=false
k3d cluster delete ocm-flux-demo ocm-plain-demo ocm-hub
```

The same commands work on Ubuntu/Linux. The demo provisions no cloud resources.
