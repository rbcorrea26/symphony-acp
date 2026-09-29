# Entrega e promoção (gates → Draft PR → CI → candidato → `ready-for-human`)

Documento do fork para o **estágio de entrega**: o que o Symphony faz depois que os
turnos do agente terminam. A decisão está em
[adr/0005](adr/0005-delivery-stage.md); a política da plataforma (gates e revisão)
está no ADR-0006 de `agentic-dev-environment`.

## Fluxo executado

```text
AgentRunner (turnos)            # executor selecionado por executor.kind (acp)
  └─ Delivery.run/3
       1. gates do consumidor (`delivery.gates`) no workspace      # exit != 0 → falha
       2. branch `pipeline/<identificador>` + commit + push        # nunca na base
       3. Draft PR (base = delivery.base_branch)                   # idempotente
       4. observa check runs do head SHA                           # CI obrigatório
       5. candidate stable = SHA com gates + CI verdes             # invalida se o head mudar
       6. review one-shot (se disponível)                          # depois do candidato
       7. handoff: rótulo + remoção do rótulo de entrada + comentário
```

## Configuração (bloco `delivery` do `WORKFLOW.md`)

| Chave | Papel |
|---|---|
| `enabled` | liga o estágio (default `false`: comportamento upstream) |
| `gates` | comando do projeto que define "passou" (obrigatório quando ligado) |
| `gates_timeout_ms` | limite do gate local |
| `base_branch` / `branch_prefix` | destino do Draft PR e nome da branch de entrega |
| `handoff_label` / `remove_entry_labels` | rótulo de handoff e remoção do rótulo de entrada (evita re-dispatch) |
| `commit_name` / `commit_email` | identidade do commit do pipeline (nunca a do usuário) |
| `ci_timeout_ms` / `ci_poll_interval_ms` | observação do CI |
| `request_review` | solicita a review one-shot depois do candidato estável |

Preflight (`Delivery.validate_config/1`): tracker GitHub, worker local e `gates`
presente. Qualquer outro caso falha o dispatch em vez de rodar um worker inútil.

## Limites declarados

- **local apenas**: com `worker.ssh_hosts` configurado o estágio falha
  (`:delivery_requires_local_worker`); um estágio remoto não faz parte desta fase;
- **sem force push**: se a branch remota divergir do workspace (por exemplo, workspace
  recriado), o push falha e exige decisão humana — a alternativa (force) está fora da
  política do pipeline;
- **observação síncrona do CI**: o worker fica ocupado até o CI concluir ou o timeout;
- **estado não persistido**: PR, ref, checks, labels e comentários no GitHub são o
  estado; não existe arquivo de candidato no Symphony;
- **retry do upstream**: falha de entrega é falha do run (o orquestrador re-tenta a
  issue com backoff). Como a issue continua em estado ativo até o handoff, use
  `agent.max_turns:` pequeno para não encadear turnos pagos enquanto o item não é
  entregue;
- **aprovação ACP**: execução headless exige `acp.auto_approve_requests: true`; com o
  default `false` o agente pede permissão, o cliente nega (fail-closed) e o run
  termina em `{:approval_required, _}` sem produzir nada (comportamento medido).

## Evidência da execução real (fase 6)

Rodada real contra o repositório descartável
`rbcorrea26/agentic-pipeline-smoke-test` (issue #1, tarefa determinística em
`answer.sh`), com o Symphony consumindo a issue pelo tracker GitHub:

| Passo | Resultado observado |
|---|---|
| tracker → workspace | issue consumida pelo poll; workspace isolado por issue em `~/automation/workspaces/<projeto>/GH-1`, com clone via `after_create` (o clone canônico não é tocado) |
| executor | `Executor.Acp` → `ACP.Client` → `~/automation/bin/cline --acp` → DeepSeek; `provider=deepseek`, `model=deepseek-v4-flash` no registro de sessão do próprio agente |
| turno | `turn=1/1`, alteração determinística de `answer.sh` (`echo "42"`) |
| gates | `scripts/agent/preflight.sh --gates` do próprio projeto, exit 0 (inclui o teste do projeto) |
| publicação | branch `pipeline/gh-1` + Draft PR criada **pelo pipeline**; diff somente `answer.sh` |
| CI | check run `gates` do GitHub Actions concluído com sucesso |
| candidato | SHA do head da branch, igual ao SHA verificado pelo CI, sem push posterior |
| review | solicitação one-shot aceita; `copilot-pull-request-reviewer[bot]` concluiu a review depois do candidato estável |
| handoff | rótulo de entrada removido, rótulo de handoff aplicado e comentário na issue com candidato, gates, CI e review |
| reconciliação | reinício do Symphony depois do handoff: **zero** dispatches, um único workspace, uma única PR e um único branch no SHA do candidato |
| retry | quando o primeiro turno terminou em `{:approval_required, _}` (default fail-closed), o orquestrador re-tentou a issue; após a correção do workflow, a entrega ocorreu no mesmo workspace |

O que **não** foi provado nesta rodada: consumidor real (fase 7), worker remoto,
cancelamento gracioso ACP e métricas de uso ACP (dívidas já registradas).
