# Demo: visão GitOps por cluster

Esta demo cria ou reutiliza dois clusters k3d locais:

- `demo-gitops`: recebe Flux e Kyverno pelo fluxo de bootstrap/GitOps.
- `demo-plain`: permanece sem Flux e Kyverno.

No Windows, execute `./Scenarios/gitops-observability-demo.ps1 -GitUrl $GitUrl`; no Ubuntu, execute `GIT_URL="$GitUrl" bash Scenarios/gitops-observability-demo.sh`. Depois inicie a dashboard Grafana e compare os estados, o inventário e os charts dos dois contextos.

Os scripts não excluem clusters existentes durante o setup. Para remover somente os clusters da demo, use o parâmetro `-Cleanup` no PowerShell ou o argumento `cleanup` no Bash. Eles não removem outras entradas do kubeconfig ou clusters.
