# Cenário: demonstração básica do OCM

O cenário cria ou reutiliza o hub `ocm-hub`, cria um spoke K3s chamado `ocm-demo`, registra o cluster no OCM e mostra o inventário. Ele não instala Flux nem Kyverno.

## Windows

Na raiz do repositório, com Docker ativo e k3d, kubectl e clusteradm no `PATH`:

```powershell
./Scenarios/ocm-basic-demo.ps1
```

Para personalizar os nomes ou a imagem K3s:

```powershell
./Scenarios/ocm-basic-demo.ps1 -HubName ocm-hub -SpokeName ocm-demo -K3sImage rancher/k3s:v1.34.12-k3s1
```

## Ubuntu / Linux

Requisitos: Docker, k3d, kubectl, clusteradm e `jq`.

```bash
bash Scenarios/ocm-basic-demo.sh
```

Os nomes e a imagem podem ser definidos por ambiente:

```bash
HUB_CLUSTER_NAME=ocm-hub SPOKE_CLUSTER_NAME=ocm-demo K3S_IMAGE=rancher/k3s:v1.34.12-k3s1 bash Scenarios/ocm-basic-demo.sh
```

## O que observar

O comando `kubectl get managedclusters` executado no hub deve listar `ocm-demo`. O YAML do `ManagedCluster` mostra o estado de aceite e as condições reportadas pelo spoke. Os dois clusters K3s são conectados à mesma rede Docker para que o agente OCM do spoke alcance a API do hub; k3d cria redes separadas por cluster por padrão.

Os scripts são idempotentes para os clusters criados com esses nomes e rede. Se um cluster de demonstração existente estiver parado, inicie-o antes de rodar novamente. Se `ocm-demo` já existir em outra rede, exclua apenas esse cluster de demonstração e rode o script novamente.

## Limpeza

Remova primeiro o registro e depois os clusters, caso não sejam usados por outros cenários:

```powershell
kubectl --context k3d-ocm-hub delete managedcluster ocm-demo --wait=false
k3d cluster delete ocm-demo
k3d cluster delete ocm-hub
```

Os mesmos comandos funcionam em Ubuntu/Linux.
