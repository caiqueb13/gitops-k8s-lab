# Cenário: OCM com e sem GitOps

Esta demo cria ou reutiliza um hub OCM (`ocm-hub`) e dois clusters K3s gerenciados:

- `ocm-flux-demo`: recebe Flux e Kyverno a partir do repositório Git público configurado no lab.
- `ocm-plain-demo`: é registrado no OCM sem Flux nem Kyverno.

Assim é possível comparar a visibilidade do inventário OCM com o estado de GitOps de cada cluster. OCM registra e gerencia a associação dos clusters; não instala Flux no cluster simples. O cluster Flux usa o fluxo de bootstrap existente e espera o HelmRelease `kyverno` ficar saudável. Como o repositório padrão é público, esta demo não cria nem consome credenciais Git.

## Windows

Requisitos: Docker ativo e `k3d`, `kubectl`, `clusteradm`, `flux` e `helm` disponíveis no `PATH`.

```powershell
./Scenarios/ocm-basic-demo.ps1
```

Personalize nomes, URL ou imagem K3s:

```powershell
./Scenarios/ocm-basic-demo.ps1 -HubName ocm-hub -FluxClusterName ocm-flux-demo -PlainClusterName ocm-plain-demo -GitUrl https://github.com/caiqueb13/gitops-k8s-lab.git
```

## Ubuntu / Linux

Requisitos: Docker, `k3d`, `kubectl`, `clusteradm`, `flux`, `helm` e `jq`.

```bash
bash Scenarios/ocm-basic-demo.sh
```

Personalize por variáveis de ambiente:

```bash
HUB_CLUSTER_NAME=ocm-hub FLUX_CLUSTER_NAME=ocm-flux-demo PLAIN_CLUSTER_NAME=ocm-plain-demo GIT_URL=https://github.com/caiqueb13/gitops-k8s-lab.git bash Scenarios/ocm-basic-demo.sh
```

Os dois spokes são conectados à rede Docker do hub para permitir que os agentes OCM alcancem a API do hub. Os scripts validam essa conexão. Clusters existentes com os nomes padrão são reutilizados; um cluster em outra rede causa erro para evitar alteração silenciosa.

O fluxo tenta inicializar e registrar os clusters com `clusteradm`. Se a versão instalada não conseguir renderizar os charts embutidos, usa os charts oficiais `cluster-manager` e `klusterlet` v1.3.1 pelo Helm. O arquivo temporário local com a configuração bootstrap é removido após a instalação. O OCM mantém o Secret `open-cluster-management-agent/bootstrap-hub-kubeconfig` em cada spoke para a comunicação de registro; esse token não autentica o Flux no Git. Esta demo não cria credenciais Git.

## O que observar

No hub, `kubectl --context k3d-ocm-hub get managedclusters` lista ambos. A tabela de detalhes mostra as condições comunicadas por cada spoke. No `ocm-flux-demo`, `flux get all -A` e `kubectl -n flux-system get helmrelease kyverno` mostram a reconciliação GitOps e o Kyverno saudável. No `ocm-plain-demo`, os namespaces `flux-system` e `kyverno` não existem.

## Encerrar e limpar

Se não precisar preservar os clusters para outros cenários, remova primeiro os registros do hub e depois os três clusters:

```powershell
kubectl --context k3d-ocm-hub delete managedcluster ocm-flux-demo ocm-plain-demo --wait=false
k3d cluster delete ocm-flux-demo ocm-plain-demo ocm-hub
```

Os mesmos comandos funcionam no Ubuntu/Linux. A demo não provisiona recursos em cloud.
