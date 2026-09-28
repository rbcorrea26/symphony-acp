# ADRs do fork (`docs/fork/adr/`)

Namespace **local** de decisões de arquitetura do fork. Não confunda os números
daqui com os da plataforma (`agentic-dev-environment/docs/architecture/adr/`).

## Convenções

- Nome: `NNNN-titulo-em-kebab-case.md` (4 dígitos, a partir de `0001`).
- Numeração sequencial e imutável; para mudar uma decisão, crie novo ADR e marque
  o anterior como `substituído por ADR-NNNN` (deste namespace).
- Estrutura obrigatória (mesma do template da plataforma): `Status`, `Data`,
  `Relacionado a`, `Contexto`, `Decisão`, `Consequências`,
  `Alternativas descartadas`, `Implementação`.
- Status: `proposto`, `aceito`, `substituído por ADR-NNNN`, `depreciado`.
- Toda decisão registrada aqui precisa dizer explicitamente **o que continua igual
  no upstream** (compatibilidade), porque o fork não pode conflitar com o
  `SPEC.md` (`elixir/AGENTS.md`: implementação pode ser superset, nunca conflito).

## Índice

| ADR | Assunto | Status |
|---|---|---|
| [`0001`](0001-executor-abstraction.md) | **executor abstraction**: o Symphony passa a acessar o executor por uma indireção (`SymphonyElixir.Executor` com behaviour e seleção por configuração), mantendo o caminho Codex app-server funcional | **aceito** (implementado na fase 3; ver `0003`) |
| [`0002`](0002-acp-protocol-mapping.md) | **ACP protocol mapping**: tradução entre o protocolo do Codex App Server e o ACP (sessão, turno, streaming, permissão, entrada do usuário, cancelamento, timeouts, ferramentas, sandbox, erros, lifecycle) | **aceito** (implementação pendente: depende do cliente ACP) |
| [`0003`](0003-phase3-executor-abstraction-scope.md) | **escopo da fase 3**: abstração implementada com executor fake determinístico de teste; sem cliente ACP, sem `acp.*`, preflight do `executor.kind` em `config.ex`/`orchestrator.ex` | **aceito** (implementado) |

Evidência que sustenta os dois ADRs: [../acp-analysis.md](../acp-analysis.md)
(matriz `D1`–`D33`, fontes, opções de abstração, segurança e decisões Q1–Q10).
A análise cobriu, no mínimo:

- `SPEC.md` §5.3.6 (`codex`), §10.1–10.7 (agent runner protocol), §4.1.5–4.1.7
  (sessão, tentativa de execução, retry) e §6.1–6.4 (configuração, reload,
  preflight);
- `elixir/lib/symphony_elixir/agent_runner.ex` (ciclo de turnos por issue);
- `elixir/lib/symphony_elixir/codex/app_server.ex` (sessão, turnos, aprovação,
  ferramentas dinâmicas, sandbox);
- `elixir/lib/symphony_elixir/config/schema.ex` e `elixir/WORKFLOW.md`
  (configuração por workflow);
- `elixir/lib/symphony_elixir/orchestrator.ex` e `elixir/lib/symphony_elixir/workspace.ex`
  (o que o executor precisa entregar ao control plane);
- a especificação oficial do ACP vigente, com versão/data registradas em
  [../acp-analysis.md](../acp-analysis.md) §3 e no ADR-0002 — sem copiar a
  especificação para cá.

## Decisões fechadas; fase 3 iniciada (incremento 1 implementado)

As questões Q1–Q10 foram decididas em 2026-09-27 e incorporadas aos ADRs (Q1/Q3/Q8/
Q9/Q10 em [0001](0001-executor-abstraction.md); Q2/Q4/Q5/Q6/Q7 em
[0002](0002-acp-protocol-mapping.md); índice em
[../acp-analysis.md](../acp-analysis.md) §10). O **primeiro incremento da fase 3**
(abstração + `executor.kind` + executor fake determinístico) está implementado e
registrado em [0003](0003-phase3-executor-abstraction-scope.md): `SymphonyElixir.Executor`
com behaviour e seleção por configuração, `SymphonyElixir.Executor.Codex` como
delegação pura e o caminho Codex intacto.

O que **não** existe ainda: cliente ACP (`SymphonyElixir.Executor.Acp`), agente ACP
falso por stdio, `acp.*`, Cline (fase 4) e DeepSeek (fase 5). O próximo passo
técnico é o cliente ACP conforme [0002](0002-acp-protocol-mapping.md), validado pelo
agente falso por stdio que [../acp-analysis.md](../acp-analysis.md) §2.5 descreve.

A decisão de plataforma que autoriza o trabalho é
`agentic-dev-environment/docs/architecture/adr/0002-acp-como-contrato-de-executor.md`
e o executor inicial está em
`.../adr/0003-cline-deepseek-como-executor-inicial.md`.

Permanecem abertos, como **dívidas registradas** (não bloqueiam a fase 3): reuso
temporário de chaves `codex.*` pelo caminho ACP, nomes internos `codex_*` e
representação de métricas ausentes no dashboard antes da integração real do
Cline.
