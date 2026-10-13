# Laboratório GitOps multi-cluster: k3d, Flux, Helm, Kyverno e Grafana

Lab local para criar clusters Kubernetes com k3d/K3s, configurar Flux e observar estado, charts e políticas Kyverno em uma página Grafana. A stack é open source e roda no computador local; não cria infraestrutura cloud nem depende de OCM.

## Como a observabilidade funciona

- O coletor Python roda no host e consulta os contextos com `kubectl` e `helm`, usando o kubeconfig já configurado. Ele não copia kubeconfigs nem valores de Secrets para o repositório ou para o Grafana.
- Prometheus armazena as métricas localmente por 15 dias (configurável); Grafana apresenta a dashboard `GitOps Lab / Fleet Compliance`.
- Clusters k3d ativos são descobertos automaticamente. Contextos não k3d entram somente quando listados em `observability/contexts.txt` ou na variável `OBSERVABILITY_CONTEXTS`.
- O coletor é somente leitura. A configuração mantém os endpoints web de Grafana e Prometheus limitados a `localhost`; a porta do coletor `9797` precisa aceitar conexões dos containers Docker e deve ser protegida pelo firewall do host.
- OCM e `clusteradm` foram removidos dos fluxos do lab. O inventário exibido é derivado dos clusters ativos e contextos explicitamente incluídos.

A dashboard exibe releases Helm (chart e versões), saúde dos `Kustomization`/`HelmRelease` e revisões do Flux, presença/saúde do Kyverno, políticas e violações atuais em PolicyReports, métricas de negações e falhas por política, versões dos controllers, estado de deployments, reinícios e uso de CPU/memória reportado por `kubectl top`.

O estado atual do repositório instala Kyverno, mas ainda não define políticas Kyverno de exemplo. Portanto, a contagem de políticas e as violações ficam zeradas/vazias até que políticas sejam instaladas no cluster.

## Estados e limites dos dados

- **Kyverno:** `installed_healthy` exige CRDs de Kyverno e os controllers admission, background e reports disponíveis. `not_installed` indica ausência de CRDs e deployments. Qualquer instalação presente que não atenda à verificação aparece como `partial_or_unhealthy`.
- **Flux em sincronia:** compara `Kustomization.status.lastAppliedRevision` com o artefato publicado pelo `GitRepository` no cluster. Não consulta o HEAD remoto do GitHub; uma origem Flux desatualizada pode fazer a comparação refletir a última revisão buscada, não o último commit remoto.
- **Kyverno Audit:** falhas em métricas de admissão e PolicyReports identificam recursos que passaram pela validação em modo Audit. PolicyReports representam o estado atual dos recursos e não são um histórico de ocorrências.
- **Kyverno Enforce:** as métricas de falha da política mostram avaliações que não passaram; a métrica de admission requests negados conta requisições recusadas por Kyverno, que também podem incluir erros de webhook. A retenção histórica começa quando Prometheus inicia a coleta.
- **Charts:** `helm list -A` mostra releases Helm acessíveis ao usuário local. Aplicações instaladas sem Helm não aparecem como charts.
- **CPU e memória:** são valores atuais de `kubectl top`; dependem do Metrics Server do cluster. Dados anteriores ao início da coleta não são reconstruídos.

## Pré-requisitos

- Docker Desktop/Engine e Docker Compose v2.
- Python 3, `kubectl`, Helm 3+ e k3d. O `flux` CLI é necessário para bootstrap e inspeção manual.
- Ubuntu: `jq` para os scripts Bash de provisionamento.
- Repositório Git acessível pelos clusters. Para repositório privado, o Secret de autenticação precisa existir no namespace `flux-system` de cada cluster antes do onboarding.

Confira as ferramentas no Windows:

```powershell
Get-Command docker, k3d, kubectl, helm, flux, python
docker info
```

No Ubuntu:

```bash
command -v docker k3d kubectl helm flux python3 jq
docker info
```

## Iniciar a dashboard

No Windows, na raiz do repositório:

```powershell
./scripts/start-dashboard.ps1
```

No Ubuntu:

```bash
bash scripts/linux/start-dashboard.sh
```

O script inicia o coletor e Prometheus/Grafana em containers e abre `http://localhost:3000`. Login inicial: `admin` / `admin`; troque a senha no primeiro acesso. A dashboard fica em **GitOps Lab → Fleet Compliance**. Os dados ficam em volumes Docker, mesmo depois de parar os containers.

Para iniciar sem abrir o navegador: `./scripts/start-dashboard.ps1 -NoBrowser` ou `bash scripts/linux/start-dashboard.sh --no-browser`.

Para encerrar:

```powershell
./scripts/stop-dashboard.ps1
```

```bash
bash scripts/linux/stop-dashboard.sh
```

Isso mantém o histórico Prometheus. Para apagar também o histórico e os dados do Grafana, execute conscientemente `docker compose -f observability/docker-compose.yml down -v`.

## Criar e descobrir clusters

Crie um cluster de teste com Flux e Kyverno via GitOps:

```powershell
$GitUrl = 'https://github.com/caiqueb13/gitops-k8s-lab.git'
./scripts/new-k3d-cluster.ps1 -Name aks-sim -GitUrl $GitUrl
```

```bash
GitUrl='https://github.com/caiqueb13/gitops-k8s-lab.git'
bash scripts/linux/new-k3d-cluster.sh aks-sim "$GitUrl"
```

Para fazer onboarding de todos os clusters k3d ativos e correspondentes ao padrão `k3d-*`, rode uma varredura:

```powershell
./scripts/sync-k3d-fleet.ps1 -GitUrl $GitUrl
```

```bash
bash scripts/linux/sync-k3d-fleet.sh "$GitUrl"
```

O watcher repete o bootstrap periodicamente enquanto estiver em execução: `./scripts/watch-k3d-fleet.ps1 -GitUrl $GitUrl` no Windows ou `bash scripts/linux/watch-k3d-fleet.sh "$GitUrl"` no Ubuntu. A dashboard descobre clusters k3d sem depender do watcher. Um cluster removido deixa de aparecer após a próxima coleta.

Para onboard de um contexto existente que não seja k3d, selecione explicitamente o contexto:

```powershell
./scripts/onboard-existing-context.ps1 -Context aks-dev -GitUrl $GitUrl
Add-Content observability/contexts.txt 'aks-dev'
```

```bash
bash scripts/linux/onboard-existing-context.sh --context aks-dev --git-url "$GitUrl"
echo aks-dev >> observability/contexts.txt
```

`observability/contexts.txt` é ignorado pelo Git. Remova a linha quando o contexto não deve mais ser consultado. Alternativamente, defina `OBSERVABILITY_CONTEXTS` com nomes separados por vírgula ao iniciar o coletor.

Para um repositório privado, passe `-GitSecretName nome-do-secret` no PowerShell ou `--git-secret nome-do-secret` no Bash. O script apenas referencia um Secret que já existe no cluster; nunca recebe nem grava o valor da credencial.

## Demo comparativa

Crie dois clusters: um com Flux/Kyverno e outro sem, para comparar os estados na dashboard:

```powershell
./Scenarios/gitops-observability-demo.ps1 -GitUrl $GitUrl
```

```bash
GIT_URL="$GitUrl" bash Scenarios/gitops-observability-demo.sh
```

O cenário não apaga clusters preexistentes. Para excluir apenas os dois clusters da demo, use `./Scenarios/gitops-observability-demo.ps1 -Cleanup` ou `bash Scenarios/gitops-observability-demo.sh cleanup`.

## Acessar e validar componentes manualmente

```powershell
kubectl --context k3d-aks-sim get nodes
helm list -A --kube-context k3d-aks-sim
flux get all -A --context k3d-aks-sim
kubectl --context k3d-aks-sim get deployments -n kyverno
kubectl --context k3d-aks-sim get clusterpolicies,policies -A
kubectl --context k3d-aks-sim get policyreports.wgpolicyk8s.io,clusterpolicyreports.wgpolicyk8s.io -A
```

No Ubuntu, os mesmos comandos funcionam no shell. Para verificar o coletor, abra `http://localhost:9797/healthz`; Prometheus fica em `http://localhost:9090`.

## Remover clusters locais

Exclua os clusters k3d que não precisa mais, um por vez:

```powershell
k3d cluster delete aks-sim
```

```bash
k3d cluster delete aks-sim
```

Clusters antigos de demos OCM, se ainda existirem (`ocm-hub`, `ocm-flux-demo`, `ocm-plain-demo`), não são apagados automaticamente pela atualização do repositório. Remova-os explicitamente com `k3d cluster delete <nome>` após confirmar que não contêm dados necessários.

## Escopo futuro

Esta implementação coleta clusters locais e contextos Kubernetes explicitamente configurados; não descobre automaticamente inventários de Azure, AWS ou Google Cloud. Em produção, um agente/collector por cluster com RBAC mínimo e envio autenticado de métricas para uma plataforma central evita distribuir kubeconfigs administrativos. A integração com inventários de provedores, identidade corporativa e comparação autenticada com o HEAD remoto do GitHub fica fora do lab atual.
