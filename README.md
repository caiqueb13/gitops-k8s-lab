# Laboratório GitOps multi-cluster: k3d (K3s) + Flux CD + Helm + Kyverno

Este laboratório testa bootstrap e reconciliação GitOps em clusters Kubernetes locais. Usa [k3d](https://k3d.io/), que executa K3s dentro de containers e é prático para criar vários clusters no mesmo computador. Isso é mais leve que clusters Kind em vários cenários, embora cada cluster ainda consuma memória e CPU. O k3d requer Docker ou outro runtime compatível. Por padrão, o script fixa K3s em `v1.34.12-k3s1`: o Docker Desktop deste ambiente expõe cgroup v1, que não é aceito pelo kubelet da série Kubernetes 1.35 por padrão. Kubernetes 1.34 entra em fim de vida em 27/10/2026; o próximo passo recomendado é migrar o runtime local para cgroup v2. Em hosts com cgroup v2, passe uma imagem K3s mantida via `-K3sImage`.

Os nomes `aks-sim`, `eks-sim` e `gke-sim` são apenas etiquetas para clusters locais. k3d/K3s não emula IAM, rede, control planes gerenciados ou integrações específicas de AKS, EKS e GKE.

## Arquitetura e limites de descoberta

- Cada cluster roda seu próprio Flux e reconcilia a mesma configuração Git.
- O bootstrap cria `GitRepository/lab-config` e `Kustomization/kyverno`. Os manifests do app só contêm namespace e recursos Helm; assim a reconciliação não substitui a URL de bootstrap por um placeholder.
- `HelmRepository` e `HelmRelease` instalam Kyverno. `version: "*"` é usado para demonstrar descoberta de novas versões, não é uma política recomendada para produção.
- `sync-k3d-fleet.ps1` consulta a lista de clusters k3d ativos e faz bootstrap dos contextos correspondentes. `watch-k3d-fleet.ps1` repete a descoberta local a cada minuto.
- No Windows, o bootstrap troca o endpoint local `host.docker.internal` gerado pelo k3d por `127.0.0.1` para acessar a porta publicada pelo Docker Desktop.
- Cluster k3d criado manualmente aparece na próxima varredura. Cluster excluído deixa de fazer parte da lista ativa e é ignorado; não é necessário contatá-lo para remover Flux, pois ele já não existe. Entradas antigas no kubeconfig podem continuar lá, mas não participam da frota ativa.

Essa descoberta é local ao computador e ao runtime k3d. Para clusters cloud criados por console, CLI ou IaC, kubeconfig não é um inventário universal. É necessário consultar periodicamente as APIs de gerenciamento de cada provedor (Azure Resource Manager, AWS EKS/Organizations e Google Cloud Resource Manager/GKE), com credenciais somente de leitura, comparar inventário com registro de clusters gerenciados e então obter credenciais Kubernetes de curta duração para bootstrap. A exclusão deve marcar o cluster como ausente e retirar sua entrada do inventário; não se deve tentar executar comandos dentro de um cluster que já foi apagado. Isso requer um reconciliador externo e integrações por provedor, ainda não incluídos neste laboratório. Não há mecanismo Kubernetes genérico que descubra clusters arbitrários sem uma fonte de inventário e credenciais.

## Pré-requisitos no Windows

- Windows 10/11 e PowerShell 7 recomendado (os scripts usam APIs .NET disponíveis também no Windows PowerShell 5.1).
- Docker Desktop/Engine em execução, ou runtime compatível com k3d.
- `k3d`, `kubectl` e `flux` no `PATH`.
- Repositório Git acessível por HTTPS pelos clusters. Para começar, use repositório público. Repositórios privados exigem um Secret Flux configurado fora do Git.

Confirme as ferramentas antes de começar:

```powershell
Get-Command k3d, kubectl, flux, git
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

## Criar três clusters locais

Na raiz do workspace:

```powershell
$GitUrl = 'https://github.com/caiqueb13/gitops-k8s-lab.git'
./scripts/new-k3d-cluster.ps1 -Name aks-sim -GitUrl $GitUrl
./scripts/new-k3d-cluster.ps1 -Name eks-sim -GitUrl $GitUrl
./scripts/new-k3d-cluster.ps1 -Name gke-sim -GitUrl $GitUrl
```

O script valida os binários antes de criar o cluster, espera o k3d e instala/reconcilia Flux, então aplica o bootstrap e espera Kyverno ficar Ready. O cluster k3d chama seu contexto `k3d-<nome>`.

## Descobrir clusters k3d criados manualmente

Uma varredura única reconcilia todos os clusters k3d ativos que correspondem ao padrão (por padrão, `k3d-*`):

```powershell
./scripts/sync-k3d-fleet.ps1 -GitUrl $GitUrl
```

Para descoberta contínua enquanto essa sessão PowerShell estiver aberta:

```powershell
./scripts/watch-k3d-fleet.ps1 -GitUrl $GitUrl -IntervalSeconds 60
```

Exemplo: crie manualmente um quarto cluster no mesmo Docker Desktop. A próxima varredura vai encontrá-lo pelo inventário k3d e instalar Flux/Kyverno:

```powershell
k3d cluster create dev04 --image rancher/k3s:v1.34.12-k3s1 --wait --timeout 5m
./scripts/sync-k3d-fleet.ps1 -GitUrl $GitUrl
```

Com `watch-k3d-fleet.ps1` em execução, essa inclusão acontece na próxima varredura. Ao remover um cluster (`k3d cluster delete dev04`), ele deixa de ser alvo na varredura seguinte. O contexto antigo, se permanecer no kubeconfig, é ignorado porque a fonte autoritativa local é `k3d cluster list`.

O watcher precisa continuar em execução. Ele não é um serviço Windows nem sobrevive a logout/reboot. Para execução contínua, pode-se criar uma tarefa agendada após validar o fluxo; a tarefa deve usar a mesma conta e runtime que possuem os clusters k3d. A descoberta ocorre em até um intervalo após a criação. Ao parar o watcher, novos clusters não serão incluídos até a próxima varredura.

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
