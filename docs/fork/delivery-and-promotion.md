# Entrega e promoção (gates → Draft PR → CI → candidato → `ready-for-human`)

Documento do fork para o **estágio de entrega**: o que o Symphony faz depois que os
turnos do agente terminam. A decisão está em
[adr/0005](adr/0005-delivery-stage.md); a política da plataforma (gates e revisão)
está no ADR-0006 de `agentic-dev-environment`.

## Fluxo executado

```text
AgentRunner (turnos)            # executor selecionado por executor.kind (acp)
  └─ Delivery.run/3
       1. aceite da issue (`pipeline_contract`) no change set do workspace   # strict → falha
       2. gates do consumidor (`delivery.gates`) no workspace                # exit != 0 → falha
       3. evidências exigidas (`required_evidence` + `delivery.evidence`)     # strict → falha
       4. branch `pipeline/<identificador>` + commit + push                  # nunca na base
       5. Draft PR (base = delivery.base_branch)                             # idempotente
       6. observa check runs do head SHA                                     # CI obrigatório
       7. candidate stable = SHA que este run publicou + gates + CI verdes    # head movido → falha
       8. review one-shot (se disponível)                                    # depois do candidato
       9. handoff: comentário (com o veredicto) e depois rótulos                # veredicto antes da promoção
```

O handoff é o único ponto que muda o estado da issue, e ele tem ordem fixa: o
**comentário com o veredicto é escrito antes** do rótulo de handoff e da remoção do
rótulo de entrada. Se a escrita do comentário falhar, a issue **não** é promovida —
ela não pode ficar marcada como entregue sem o veredicto legível por máquina que a
#13/#14 vão consumir.

Invariante: *promotion state must not advance if the machine-readable verdict was
not durably persisted*. Ele é executado em `handoff/8` (o `ensure_comment` precede o
`add_labels`) e coberto por teste: uma escrita de comentário que falha deixa a issue
sem rótulo de handoff, com o rótulo de entrada no lugar e sem comentário.

O **candidato fica amarrado ao que foi aceito**: o aceite e os gates rodam no
conteúdo do workspace que este run publica. Se o head da branch observado no fim da
espera do CI for outro commit (um push concorrente), o run falha com
`delivery_candidate_replaced` em vez de promover um head que ninguém aceitou; o
retry reexecuta o aceite sobre o conteúdo e republica. O mesmo vale para o run
**reconciliado** (retry de um candidato já publicado, sem change set novo no
worktree): o candidato dele é o **HEAD local** — o conteúdo que este workspace tem em
mãos —, e o aceite é **recalculado** sobre ele, lido do Git contra a branch base
(`delivery.base_branch`), com as evidências do contrato em vigor; uma branch que
andou (push de fora, antes ou durante a observação) é recusada com
`delivery_candidate_replaced` em vez de receber os rótulos deste run.

## As três camadas de verificação

| # | Camada | Pergunta | Onde |
|---|---|---|---|
| 1 | aceite (`pipeline_contract`) | a **issue** foi satisfeita? (escopo, evidências, proibições) | `Delivery.Acceptance` + `PipelineContract` |
| 2 | gates do repositório | o **repositório** continua válido? | `delivery.gates` |
| 3 | CI | o **candidato publicado** passou no CI? | check runs do head SHA |

Gates verdes **não** substituem aceite: foi exatamente a falha medida no primeiro
ensaio real (issue #64 / PR #65 do site Estúdio Angel Lopes — a issue pedia dois
arquivos, a implementação alterou outros e os gates ficaram verdes). A decisão,
o schema v1 e os limites estão em [adr/0006](adr/0006-acceptance-contract.md).

### Contrato de aceite na issue

O aceite lê um `pipeline_contract` (schema v1, corpo da issue): escopo
`strict`/`advisory` sobre o change set, evidências nomeadas e proibições
(`remote_access`/`deploy`) por varredura limitada das linhas adicionadas.

```yaml
pipeline_contract:
  version: 1
  scope_mode: strict                 # strict | advisory
  expected_paths:                    # globs; cada um precisa ser entregue
    - docs/changes/2026-09-30-pipeline-e2e-smoke.md
    - tests/agent/run-tests.sh
  allowed_extra_paths: []
  required_evidence:
    - agent-tests
    - repository-gates
  remote_access: false
  deploy: false
```

- `strict`: achado bloqueia a publicação; `advisory`: achado é reportado e o
  handoff continua (a revisão arquitetural decide, #14);
- issue **sem** contrato → camada `not_configured` (comportamento anterior intacto);
- evidência é **nome**: o registry é `delivery.evidence` (workflow) + o nome
  reservado `repository-gates` (satisfeito pelo estágio de gates);
- achados são findings com código estável, e o veredicto é persistido como JSON no
  comentário de handoff (interface para #13/#14).

Schema, semântica por caso de diff, tabela de códigos, o que é verificável e o que
**não** é, e os limites declarados: [acceptance-contract.md](acceptance-contract.md)
(decisão em [adr/0006](adr/0006-acceptance-contract.md)).

> `acceptance PASS` ≠ `repository gates PASS` ≠ `CI PASS` ≠ `review PASS` ≠ `architect PASS`.

A review (`waiting-review`/`rework`) e o architect runner **não** existem nesta
fase: o handoff continua sendo o do ADR-0005 e a fase 7b **não** está concluída
(#13 e #14 continuam pendentes).


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
| `evidence` | mapa nome → comando das evidências que o contrato de aceite pode exigir (`repository-gates` é reservado e satisfeito pelos gates) |

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
  estado; não existe arquivo de candidato no Symphony (o relatório do aceite
  também não é persistido — ele vive no log e no comentário de handoff);
- **o aceite é declarativo e heurístico**: o contrato é data da issue (nunca
  código), o escopo é comparado com o change set (rename conta pelo destino **e**
  pela origem, que é uma deleção, e arquivos novos entram individualmente) e a
  proibição é uma varredura limitada
  das linhas adicionadas. Contrato inválido (versão desconhecida, campo
  desconhecido, padrão absoluto/`..`, YAML quebrado) falha o run em vez de ser
  ignorado; a varredura de proibição pode ter falso positivo e o relatório marca
  `truncated` quando o limite de linhas foi atingido;
- **retry do upstream**: falha de entrega é falha do run (o orquestrador re-tenta a
  issue com backoff). Como a issue continua em estado ativo até o handoff, use
  `agent.max_turns:` pequeno para não encadear turnos pagos enquanto o item não é
  entregue;
- **aprovação ACP (risco declarado, não contenção)**: execução headless exige
  `acp.auto_approve_requests: true`; com o default `false` o agente pede permissão, o
  cliente nega (fail-closed) e o run termina em `{:approval_required, _}` sem produzir
  nada (comportamento medido). Auto-aprovar **não** restringe o processo do agente: o
  ACP não promete sandbox, o `cwd` validado sob o workspace root é diretório de
  trabalho e não barreira de filesystem, não há isolamento de filesystem/processo/rede
  e o agente herda os privilégios normais do usuário que executa o pipeline. O que
  existe: o token do tracker é removido do processo do agente (`unset`) e o cliente ACP
  não anuncia capabilities `fs`/`terminal` — o que limita o que o agente pediria ao
  Symphony, não o que ele faz por conta própria. Essa ressalva foi resolvida **na
  plataforma** depois desta prova (fase 6b, issue `rbcorrea26/agentic-dev-environment#26`):
  `acp.command` passa a apontar para o wrapper contido
  (`$HOME/automation/bin/cline-sandboxed --acp`), que monta uma allowlist de filesystem
  com bubblewrap antes de lançar o agente
  ([ADR-0008](https://github.com/rbcorrea26/agentic-dev-environment/blob/main/docs/architecture/adr/0008-contencao-do-agente-acp.md)).
  Nenhum código deste fork mudou; a rede continua compartilhada com o host.

## Evidência da execução real (fase 6)

Rodada real contra o repositório descartável
`rbcorrea26/agentic-pipeline-smoke-test` (issue #1, tarefa determinística em
`answer.sh`), com o Symphony consumindo a issue pelo tracker GitHub:

| Passo | Resultado observado |
|---|---|
| tracker → workspace | issue consumida pelo poll; workspace isolado por issue em `~/automation/workspaces/<projeto>/GH-1`, com clone via `after_create` (o clone canônico não é tocado) |
| executor | `Executor.Acp` → `ACP.Client` → `~/automation/bin/cline --acp` → DeepSeek; `provider=deepseek`, `model=deepseek-v4-flash` no registro de sessão do próprio agente (desde a fase 6b o comando canônico é o wrapper contido `~/automation/bin/cline-sandboxed --acp`, sem mudança neste fork) |
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
