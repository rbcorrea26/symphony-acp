# Ciclo de vida sob demanda (extensão do fork)

Decisão da plataforma: [ADR-0009](https://github.com/rbcorrea26/agentic-dev-environment/blob/main/docs/architecture/adr/0009-execucao-sob-demanda-do-pipeline.md).
Operação na plataforma:
[dispatcher.md](https://github.com/rbcorrea26/agentic-dev-environment/blob/main/docs/operations/dispatcher.md).

## 1. O problema

O comportamento upstream do Symphony é **residente**: ele faz poll do tracker para sempre,
o que é correto para um serviço e errado para o primeiro estágio da plataforma agentic. O
ensaio E2E real do consumidor (issue #64 / PR #65 da plataforma) mostrou que o humano
precisava iniciar o Symphony à mão, escolher o `WORKFLOW.md` e acompanhar o processo — o
usuário virava *message bus* entre os agentes.

A extensão resolve isso **sem** matar processo: o Symphony ganha um modo explícito de
execução sob demanda que **encerra o ciclo sozinho** quando não há mais trabalho.

Nunca use `kill`, `timeout` de shell ou leitura do dashboard para isso: o encerramento é
uma decisão do control plane, e a idempotência (branch/PR/review) depende dela.

## 2. Opções de linha de comando (aditivas)

```
symphony [--logs-root <path>] [--port <port>]
         [--exit-when-idle] [--issue <identificador>]
         [--resume-only] [--max-runtime-seconds <n>]
         [path-to-WORKFLOW.md]
```

| Opção | Efeito |
|---|---|
| `--exit-when-idle` | encerra o processo quando o ciclo não tem mais nada a fazer (nada rodando, nada em retry, nada bloqueado, nenhum claim pendente e nenhum candidato despachável) |
| `--issue <id>` | limita o ciclo a **uma** issue (ex.: `GH-64`); sem ela, o comportamento upstream (todos os candidatos) permanece |
| `--resume-only` | avança um estado assíncrono (CI, review, arquiteto) do candidato **já publicado**, sem rodar os turnos do agente de novo |
| `--max-runtime-seconds <n>` | teto **gracioso** de duração do processo (`n` > 0; `0` e negativo são recusados como uso inválido); ao atingir, encerra com código 3 em vez de ficar preso |

Nenhuma opção existente do upstream foi renomeada, removida ou teve o default alterado: sem
as flags, o comportamento é exatamente o upstream (poll contínuo).

O teto de duração é um **prazo**, não um intervalo de poll: o próximo ciclo é agendado no
vencimento dele (o que vier primeiro entre o poll normal e o prazo) e nenhum trabalho novo é
despachado depois do prazo — mas o ciclo ainda avalia a carga, para que um ciclo
comprovadamente idle termine com `0` em vez de `3` (com `3` o dispatcher repetiria um ciclo que
já terminou).

Limite declarado: a checagem do prazo acontece **entre** ciclos. Um ciclo que fica bloqueado
dentro do cliente do tracker (conexão sem resposta até o timeout do próprio cliente) atrasa o
encerramento por essa duração — tornar o poll assíncrono para reagir durante a chamada está
**fora** deste incremento.

## 3. Códigos de saída

| Código | Significado |
|---|---|
| `0` | ciclo concluído e nada pendente (idle; trabalho pode ter rodado) |
| `1` | falha de inicialização (CLI/workflow: arquivo ausente, aplicação não sobe) |
| `3` | ainda havia trabalho pendente quando o teto de duração foi atingido |

O dispatcher da plataforma interpreta esses códigos: `3` é "chama de novo depois" e `1` é
falha que merece atenção do operador.

Falha de tracker/config **durante** o ciclo não encerra o processo: como no upstream, o ciclo
segue e tenta de novo no próximo poll (com `--max-runtime-seconds`, o fim vem como `3`).

O código pedido pelo ciclo é registrado por `Shutdown.request/2` e **preservado até o fim do
processo**: quando a árvore de supervisão cai (`:shutdown`), a CLI encerra a VM com esse código,
não com o default residente. Sem ciclo sob demanda não existe registro e o mapeamento residente
do upstream continua (`:normal` → `0`, resto → `1`).

## 4. Por que `resume-only`

Review e CI são **assíncronos**. Quando o pipeline retoma a issue no ciclo seguinte, o
workspace é recriado pela `Workspace` e o candidato já está publicado no PR. Rodar o agente
de novo nesse momento gastaria tokens e poderia produzir um commit novo — ou seja, um
*candidate* novo e uma review nova — sem que ninguém tenha pedido. Com `--resume-only` o
ciclo executa apenas a etapa de entrega (`SymphonyElixir.Delivery`) sobre o que já existe.

## 5. Superfície alterada

| Arquivo | Natureza | Comportamento upstream afetado? |
|---|---|---|
| `elixir/lib/symphony_elixir/shutdown.ex` | novo | não (só é chamado pelo modo sob demanda) |
| `elixir/lib/symphony_elixir/cli.ex` | alterado (aditivo) | não: as quatro flags são novas; sem elas, o fluxo é o upstream. O único ponto tocado no caminho residente é o encerramento, que passa a preservar o código registrado pelo ciclo quando ele existe |
| `elixir/lib/symphony_elixir/orchestrator.ex` | alterado | **sim, mínimo**: o ciclo de poll passa a devolver também "houve algo despachável neste ciclo" (para decidir o idle) e o filtro `--issue` só age quando configurado |
| `elixir/lib/symphony_elixir/agent_runner.ex` | alterado (aditivo) | não: `resume-only` apenas pula os turnos do agente; sem a flag nada muda |
| `elixir/test/symphony_elixir/on_demand_test.exs` | novo | não |

## 6. Estado da fase 7b no fork

Implementado e testado aqui: o lifecycle acima (`--exit-when-idle`, `--issue`,
`--resume-only`, `--max-runtime-seconds`, `SymphonyElixir.Shutdown`), com a suíte offline
(tracker `memory` + shutdown injetado).

**Pendente** (não implementado neste incremento — não trate como pronto):

- contrato de aceite (`pipeline_contract`) em `strict`/`advisory`;
- máquina de estados da review (`waiting-review`/`rework` por *candidate* SHA, findings
  materiais, limite de ciclos) — hoje o estágio de entrega ainda escreve o handoff antigo;
- architect runner (`ARCHITECT_PASS`/`REWORK`/`BLOCKED`) como gate antes de
  `ready-for-human`.

Enquanto esses itens não existirem, `ready-for-human` **não** é o resultado confiável da
fase 7b e o dispatcher não deve ser tratado como operacional em consumidor real.
