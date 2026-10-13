# Scenario: basic OCM demo

This scenario creates or reuses the `ocm-hub` hub, creates an `ocm-demo` K3s spoke, registers it with OCM, and displays the inventory. It does not install Flux or Kyverno.

## Windows

From the repository root, with Docker running and k3d, kubectl, and clusteradm on `PATH`:

```powershell
./Scenarios/ocm-basic-demo.ps1
```

Customize the names or K3s image if needed:

```powershell
./Scenarios/ocm-basic-demo.ps1 -HubName ocm-hub -SpokeName ocm-demo -K3sImage rancher/k3s:v1.34.12-k3s1
```

## Ubuntu / Linux

Requirements: Docker, k3d, kubectl, clusteradm, and `jq`.

```bash
bash Scenarios/ocm-basic-demo.sh
```

Set names and the image through environment variables:

```bash
HUB_CLUSTER_NAME=ocm-hub SPOKE_CLUSTER_NAME=ocm-demo K3S_IMAGE=rancher/k3s:v1.34.12-k3s1 bash Scenarios/ocm-basic-demo.sh
```

## What to observe

The `kubectl get managedclusters` command on the hub should list `ocm-demo`. The `ManagedCluster` YAML shows acceptance and conditions reported by the spoke. Both K3s clusters are attached to the same Docker network so the OCM agent in the spoke can reach the hub API; k3d creates a separate network per cluster by default.

The scripts are idempotent for clusters created with these names and network. If an existing demo cluster is stopped, start it before rerunning. If `ocm-demo` already exists on a different network, delete only that demo cluster and rerun the script.

## Cleanup

Remove the OCM registration first, then delete the clusters if no other scenario uses them:

```powershell
kubectl --context k3d-ocm-hub delete managedcluster ocm-demo --wait=false
k3d cluster delete ocm-demo
k3d cluster delete ocm-hub
```

The same commands work on Ubuntu/Linux.
