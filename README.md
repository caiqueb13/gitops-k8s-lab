# Laboratório GitOps multi-cluster: k3d/K3s, OCM, Flux CD, Helm e Kyverno

Este laboratório testa bootstrap e reconciliação GitOps em clusters Kubernetes locais. Usa [k3d](https://k3d.io/), que executa K3s dentro de containers e é prático para criar vários clusters no mesmo computador. Isso é mais leve que clusters Kind em vários cenários, embora cada cluster ainda consuma memória e CPU. O k3d requer Docker ou outro runtime compatível. Por padrão, o script fixa K3s em `v1.34.12-k3s1`: o Docker Desktop deste ambiente expõe cgroup v1, que não é aceito pelo kubelet da série Kubernetes 1.35 por padrão. Kubernetes 1.34 entra em fim de vida em 27/10/2026; o próximo passo recomendado é migrar o runtime local para cgroup v2. Em hosts com cgroup v2, passe uma imagem K3s mantida via `-K3sImage`.

Os nomes `aks-sim`, `eks-sim` e `gke-sim` são apenas etiquetas para clusters locais. k3d/K3s não emula IAM, rede, control planes gerenciados ou integrações específicas de AKS, EKS e GKE.

## Arquitetura e limites de descoberta

- Cada cluster roda seu próprio Flux e reconcilia a mesma configuração Git.
- O bootstrap cria `GitRepository/lab-config` e `Kustomization/kyverno`. Os manifests do app só contêm namespace e recursos Helm; assim a reconciliação não substitui a URL de bootstrap por um placeholder.
- `HelmRepository` e `HelmRelease` instalam Kyverno. `version: "*"` é usado para demonstrar descoberta de novas versões, não é uma política recomendada para produção.
- `sync-k3d-fleet.ps1` consulta a lista de clusters k3d ativos e faz bootstrap dos contextos correspondentes. `watch-k3d-fleet.ps1` repete a descoberta local a cada minuto.
- No Windows, o bootstrap troca o endpoint local `host.docker.internal` gerado pelo k3d por `127.0.0.1` para acessar a porta publicada pelo Docker Desktop.
- Cluster k3d criado manualmente aparece na próxima varredura. Quando um cluster gerenciado pela frota é excluído, a próxima varredura remove sua entrada OCM sem tentar contatá-lo. Entradas antigas no kubeconfig podem continuar lá, mas não participam da frota ativa.

Essa descoberta é local ao computador e ao runtime k3d. O OCM registra os clusters locais que passaram pelo onboarding, e a auditoria verifica seus estados. Para clusters cloud criados por console, CLI ou IaC, kubeconfig não é um inventário universal. É necessário consultar periodicamente as APIs de gerenciamento de cada provedor (Azure Resource Manager, AWS EKS/Organizations e Google Cloud Resource Manager/GKE), com credenciais somente de leitura, comparar os inventários e obter credenciais Kubernetes de curta duração para bootstrap. A exclusão deve retirar a entrada do inventário sem tentar contatar um cluster apagado. O reconciliador cloud e as integrações por provedor não fazem parte deste laboratório. Não há mecanismo Kubernetes genérico que descubra clusters arbitrários sem uma fonte de inventário e credenciais.

## Pré-requisitos no Windows

- Windows 10/11 e PowerShell 7 recomendado (os scripts usam APIs .NET disponíveis também no Windows PowerShell 5.1).
- Docker Desktop/Engine em execução, ou runtime compatível com k3d.
- `k3d`, `kubectl`, `flux`, `clusteradm` e Helm 3+ no `PATH` para o fluxo OCM.
- Repositório Git acessível por HTTPS pelos clusters. Para começar, use repositório público. Repositórios privados exigem um Secret Flux configurado fora do Git.

Confirme as ferramentas antes de começar:

```powershell
Get-Command k3d, kubectl, flux, clusteradm, helm, git
docker info
```

Se o Windows bloquear os scripts por causa da Execution Policy, não altere a política global. Execute cada script em um processo com bypass temporário, por exemplo:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\new-k3d-cluster.ps1 -Name aks-sim -GitUrl $GitUrl
```

Substitua o arquivo/argumentos conforme o comando que pretende executar. Em PowerShell 7, use `pwsh.exe` no lugar de `powershell.exe`.

## Publicar o repositório no GitHub

O repositório público do laboratório foi criado em [github.com/caiqueb13/gitops-k8s-lab](https://github.com/caiqueb13/gitops-k8s-lab). Para autenticar novamente pelo navegador, instale GitHub CLI (`gh`) e rode `gh auth login --web`, escolhendo GitHub.com e HTTPS. O login autoriza o Git CLI no computador. Não passe tokens nos manifests ou no Git.

```powershell
git remote -v
git status --short --branch
```

O remoto configurado é `https://github.com/caiqueb13/gitops-k8s-lab.git`. Ele é público para que os clusters façam clone sem Secret. Não armazene credenciais no repositório.

## Preparar o hub OCM local

O hub OCM é um cluster k3d separado que mantém o inventário. O script cria `ocm-hub` se ainda não existir e inicializa o OCM. Ele não instala Flux/Kyverno no hub nem cria recursos cloud:

```powershell
./scripts/new-ocm-hub.ps1
```

O contexto padrão do hub é `k3d-ocm-hub`. Os scripts usam os charts oficiais OCM v1.3.1 como fallback se o `clusteradm` não conseguir renderizar os charts embutidos. Em Ubuntu, instale `jq` além de k3d, kubectl, Flux, clusteradm e Helm e use o script Bash equivalente:

```bash
bash scripts/linux/new-ocm-hub.sh
```

O onboarding instala componentes no cluster de destino e exige que a identidade do contexto Kubernetes tenha privilégios suficientes para criar CRDs, deployments e RBAC. Para registrar spokes no OCM local, eles precisam alcançar o hub. O uso de `--force-internal-endpoint-lookup` é apropriado para os clusters locais deste lab; clusters remotos precisam de um endpoint do hub acessível por rede.

Para comparar onboarding, rode `./Scenarios/ocm-basic-demo.ps1` no Windows ou `bash Scenarios/ocm-basic-demo.sh` no Ubuntu. O cenário registra dois spokes no OCM: um com Flux e Kyverno via GitOps e outro sem esses componentes. O roteiro e a limpeza estão em [Scenarios/README.md](Scenarios/README.md).

## Criar três clusters locais

Na raiz do workspace:

```powershell
$GitUrl = 'https://github.com/caiqueb13/gitops-k8s-lab.git'
./scripts/new-ocm-hub.ps1
./scripts/new-k3d-cluster.ps1 -Name aks-sim -GitUrl $GitUrl
./scripts/new-k3d-cluster.ps1 -Name eks-sim -GitUrl $GitUrl
./scripts/new-k3d-cluster.ps1 -Name gke-sim -GitUrl $GitUrl
```

Execute `new-ocm-hub.ps1` primeiro. O script de cluster valida os binários, cria o cluster, instala/reconcilia Flux, aplica o bootstrap, espera Kyverno ficar Ready e registra o spoke no OCM. O contexto k3d é `k3d-<nome>`.

Em Ubuntu, o fluxo equivalente é:

```bash
GitUrl='https://github.com/caiqueb13/gitops-k8s-lab.git'
bash scripts/linux/new-ocm-hub.sh
bash scripts/linux/new-k3d-cluster.sh aks-sim "$GitUrl"
bash scripts/linux/new-k3d-cluster.sh eks-sim "$GitUrl"
bash scripts/linux/new-k3d-cluster.sh gke-sim "$GitUrl"
```

## Descobrir clusters k3d criados manualmente

Uma varredura única reconcilia todos os clusters k3d ativos que correspondem ao padrão (por padrão, `k3d-*`):

```powershell
./scripts/sync-k3d-fleet.ps1 -GitUrl $GitUrl -HubContext k3d-ocm-hub
```

Para descoberta contínua enquanto essa sessão PowerShell estiver aberta:

```powershell
./scripts/watch-k3d-fleet.ps1 -GitUrl $GitUrl -HubContext k3d-ocm-hub -IntervalSeconds 60
```

Exemplo: crie manualmente um quarto cluster no mesmo Docker Desktop. A próxima varredura vai encontrá-lo pelo inventário k3d e instalar Flux/Kyverno:

```powershell
k3d cluster create dev04 --image rancher/k3s:v1.34.12-k3s1 --wait --timeout 5m
./scripts/sync-k3d-fleet.ps1 -GitUrl $GitUrl -HubContext k3d-ocm-hub
```

Com `watch-k3d-fleet.ps1` em execução, a inclusão acontece na próxima varredura. Ao excluir um cluster (`k3d cluster delete dev04`), ele deixa de ser alvo e sua entrada OCM marcada como `k3d-fleet` é removida na varredura seguinte. O contexto antigo, se permanecer no kubeconfig, é ignorado porque a fonte autoritativa local é `k3d cluster list`.

O watcher precisa continuar em execução. Ele não é um serviço Windows nem sobrevive a logout/reboot. Para execução contínua, pode-se criar uma tarefa agendada após validar o fluxo; a tarefa deve usar a mesma conta e runtime que possuem os clusters k3d. A descoberta ocorre em até um intervalo após a criação. Ao parar o watcher, novos clusters não serão incluídos até a próxima varredura.

No Ubuntu, use `bash scripts/linux/sync-k3d-fleet.sh "$GitUrl"` para uma varredura ou `bash scripts/linux/watch-k3d-fleet.sh "$GitUrl"` para descoberta contínua. A variável `HUB_CONTEXT` pode trocar o contexto do hub.

## Onboard de um cluster existente

Para um cluster que já existe e aparece no kubeconfig, não é necessário recriá-lo. Escolha o contexto exato; o script valida acesso, instala Flux apenas se estiver ausente, configura a origem Git e Kyverno e registra o cluster no hub:

```powershell
$Context = 'k3d-existing'
$GitUrl = 'https://github.com/caiqueb13/gitops-k8s-lab.git'
./scripts/onboard-existing-context.ps1 -Context $Context -GitUrl $GitUrl -HubContext k3d-ocm-hub
```

Se Flux já estiver instalado, o script verifica a saúde dos controllers. Uma instalação parcial ou recursos `GitRepository/lab-config` / `Kustomization/kyverno` com configuração conflitante interrompem o onboarding para evitar sobrescrita silenciosa. O contexto precisa ter permissões para instalar Flux e criar os recursos do lab. Para um repositório privado, `-GitSecretName` referencia um **Secret Kubernetes** já existente no próprio cluster, no namespace `flux-system`. Ele contém a credencial de leitura que o `source-controller` do Flux usa para clonar o Git (por exemplo, credenciais HTTPS ou uma chave SSH); não é um GitHub Actions Secret, e o script não recebe nem lê os valores:

```powershell
./scripts/onboard-existing-context.ps1 -Context $Context -GitUrl 'https://github.com/org/private-repo.git' -GitSecretName github-auth -HubContext k3d-ocm-hub
```

O script só verifica a existência do Secret e grava seu nome em `GitRepository/lab-config.spec.secretRef`; os valores permanecem no cluster. O bootstrap atual usa autenticação Git genérica via `secretRef`. Uma credencial GitHub App requer também `spec.provider: github`, que este fluxo local ainda não configura. Em produção, crie esse Secret por um cofre/sincronizador confiável e configure o provider compatível. Para o repositório público do lab, omita `-GitSecretName`. Em Ubuntu:

```bash
bash scripts/linux/onboard-existing-context.sh --context k3d-existing --git-url 'https://github.com/caiqueb13/gitops-k8s-lab.git' --hub-context k3d-ocm-hub
```

## Auditar inventário e saúde

O auditor consulta os `ManagedCluster` registrados no OCM, testa cada contexto registrado, verifica os quatro deployments Flux, `GitRepository/lab-config`, `Kustomization/kyverno`, `HelmRelease/kyverno` e os pods Kyverno. Ele grava no objeto OCM os estados e o horário da última auditoria; imprime tabela por padrão e também aceita JSON/CSV:

```powershell
./scripts/audit-ocm-fleet.ps1
./scripts/audit-ocm-fleet.ps1 -Format Json -FailOnUnhealthy
```

No Ubuntu:

```bash
bash scripts/linux/audit-ocm-fleet.sh
FAIL_ON_UNHEALTHY=true bash scripts/linux/audit-ocm-fleet.sh json
```

`Ready` significa que os checks configurados passaram naquele momento; não é uma auditoria completa de segurança. O auditor precisa de contextos kubeconfig válidos para o hub e para cada spoke registrado.

## Verificar reconciliação

Para acessar um cluster, use o contexto `k3d-<nome>`. Confira o contexto ativo antes de executar comandos para evitar atuar no cluster errado:

```powershell
kubectl config get-contexts
kubectl config use-context k3d-aks-sim
kubectl config current-context
```

Também é possível informar `--context` em cada comando, sem alterar o contexto ativo. Valide os componentes instalados no cluster:

```powershell
k3d cluster list
flux get all -A --context k3d-aks-sim
kubectl --context k3d-aks-sim get pods -n kyverno
kubectl --context k3d-aks-sim get helmreleases -n flux-system
kubectl --context k3d-aks-sim get pods -n flux-system
```

Espere os recursos Flux aparecerem como `Ready=True`, Kyverno ficar `Running` e o HelmRelease `kyverno` ficar `Ready=True`. Repita usando `k3d-eks-sim` e `k3d-gke-sim` para validar os outros clusters. Para observar status e eventos de falha:

```powershell
flux get sources all -A --context k3d-aks-sim
flux get kustomizations -A --context k3d-aks-sim
flux get helmreleases -A --context k3d-aks-sim
kubectl --context k3d-aks-sim describe helmrelease kyverno -n flux-system
```

Edite os manifests, faça commit e push; os clusters consultam Git a cada minuto e reconciliam a Kustomization a cada cinco minutos, aproximadamente. `HelmRelease Ready` confirma a reconciliação do release, mas não é uma auditoria completa da saúde ou segurança do cluster.

## Atualizações de charts

`version: "*"` acompanha a versão estável mais recente encontrada no repositório Helm. Uma nova versão pode ser incompatível ou falhar durante a instalação. Para produção, fixe uma versão homologada e use Renovate para propor pull requests, valide primeiro em um cluster canário e promova depois para os demais, com plano de rollback.

## Identidade Azure, GitHub privado e secrets

Para uma frota com dezenas ou centenas de AKS existentes, mantenha separadas as identidades de inventário/onboarding, a identidade usada pelo Flux e as credenciais do repositório. A UAMI do reconciliador Azure não autentica no GitHub.

**Caminho recomendado para AKS:** inventarie os clusters via Azure Resource Graph/ARM e use Azure Policy `DeployIfNotExists` para instalar a extensão Flux e a configuração em clusters atuais e novos, por escopo de subscription ou resource group. A identidade gerenciada da atribuição recebe permissões ARM mínimas para remediação das extensões/configurações. Isso evita distribuir kubeconfig admin para um serviço central. Pilote em poucos clusters, monitore o estado e amplie gradualmente. [GitOps em escala com Azure Policy](https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/use-azure-policy-flux-2) e [efeito DeployIfNotExists](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-deploy-if-not-exists).

**Alternativa autogerida:** uma automação pode usar identidade Entra/UAMI para obter credenciais e instalar Flux diretamente. Azure RBAC no plano ARM e autorização Kubernetes são controles distintos. `Azure Kubernetes Service RBAC Cluster Admin` concede acesso administrativo ao cluster; não o atribua amplamente por conveniência. Restrinja escopo e duração, proteja o runner e prefira a extensão gerenciada quando isso atender ao caso. [Acesso e permissões de kubeconfig AKS](https://learn.microsoft.com/en-us/azure/aks/control-kubeconfig-access).

Para um repositório GitHub privado, Flux precisa de credencial Git em cada cluster. GitHub Actions Secrets são para workflows do Actions; os pods não conseguem buscar esses valores diretamente. Para Flux autogerido, prefira GitHub App com acesso somente leitura e armazene a chave privada no Azure Key Vault. External Secrets Operator pode sincronizá-la para um Secret local usando Workload Identity. Flux usa os dados da GitHub App para obter tokens de instalação curtos. Configure primeiro a identidade e o provedor de secrets por um mecanismo de bootstrap confiável; não dependa de um repositório privado para entregar a credencial necessária para clonar esse mesmo repositório. [Autenticação GitHub App no Flux](https://fluxcd.io/flux/components/source/gitrepositories/).

A chave privada da App é duradoura e deve ser rotacionada manualmente: crie uma segunda chave, atualize o cofre, espere a sincronização, confirme que Flux reconcilia nos clusters e então revogue a antiga. Tokens de instalação são temporários e o fluxo GitHub App do Flux os renova durante a autenticação. Para a extensão Flux Azure, use os mecanismos documentados (HTTPS/SSH, provider e Secret local/`localAuthRef`) e confira o suporte da versão escolhida antes de assumir compatibilidade com toda modalidade de autenticação do Flux autogerido. [Parâmetros Git/Secret da extensão Flux](https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/gitops-flux2-parameters), [rotação de chave GitHub App](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps).

Credenciais de charts como Wiz seguem o mesmo padrão: guardar a service account no cofre, sincronizar apenas para o namespace que o chart exige e conceder o menor escopo disponível, idealmente credencial separada por ambiente/cluster. Não coloque a service account em Git ou GitHub Actions Secrets esperando que o cluster a leia.

## Limpeza local

Para apenas encerrar o laboratório e liberar CPU e memória, pare o watcher com `Ctrl+C` na janela em que ele está rodando. Em seguida, confira os clusters e pare somente os clusters deste laboratório. A parada preserva os dados e workloads para uso posterior:

```powershell
k3d cluster list
k3d cluster stop aks-sim
k3d cluster stop eks-sim
k3d cluster stop gke-sim
```

Para retomar o laboratório:

```powershell
k3d cluster start aks-sim
k3d cluster start eks-sim
k3d cluster start gke-sim
```

Para excluir definitivamente os clusters, confira os nomes e execute os comandos individualmente. Essa operação remove os clusters, workloads e dados locais associados:

```powershell
k3d cluster list
k3d cluster delete aks-sim
k3d cluster delete eks-sim
k3d cluster delete gke-sim
```

Não use `k3d cluster delete --all` em uma máquina compartilhada ou com outros clusters. Os contextos kubeconfig podem ser removidos separadamente depois da conferência, mas não são necessários para a descoberta da frota k3d ativa.

## O que falta para cloud e escala

O laboratório local valida GitOps, Helm e bootstrap. Ele ainda não descobre clusters cloud criados fora do pipeline. O próximo incremento recomendado é um inventário por provedor com permissões read-only, estado de onboarding explícito, credenciais de curta duração e reconciliação periódica. Adicione alertas/auditoria para clusters presentes no provedor mas ausentes do inventário Flux, e para clusters gerenciados cujo acesso foi revogado. Não provisionar cloud faz parte do escopo deste laboratório local.

Kyverno é um policy engine e admission controller. Ele não substitui agente de visibilidade, coleta de logs ou sensor CSPM. Adicione charts separados apenas quando esses comportamentos forem requisitos do laboratório.
