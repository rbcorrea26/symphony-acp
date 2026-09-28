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
| [`0001`](0001-executor-abstraction.md) | **executor abstraction**: o Symphony passa a acessar o executor por uma indireção (`SymphonyElixir.Executor` com behaviour e seleção por configuração), mantendo o caminho Codex app-server funcional | **proposto** — aguardando revisão |
| [`0002`](0002-acp-protocol-mapping.md) | **ACP protocol mapping**: tradução entre o protocolo do Codex App Server e o ACP (sessão, turno, streaming, permissão, entrada do usuário, cancelamento, timeouts, ferramentas, sandbox, erros, lifecycle) | **proposto** — aguardando revisão |

Evidência que sustenta os dois ADRs: [../acp-analysis.md](../acp-analysis.md)
(matriz `D1`–`D33`, fontes, opções de abstração, segurança e questões abertas).
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

## Implementação ainda não iniciada

Nenhuma linha de código ACP existe: os ADRs estão em `proposto` e a
implementação é a fase 3 do roadmap
(`agentic-dev-environment/docs/architecture/roadmap.md`), com a decisão de
plataforma que autoriza o trabalho em
`agentic-dev-environment/docs/architecture/adr/0002-acp-como-contrato-de-executor.md`
e o executor inicial em
`.../adr/0003-cline-deepseek-como-executor-inicial.md`.

Antes de codificar, as questões Q1–Q3 de
[../acp-analysis.md](../acp-analysis.md) §10 (estrutura/nomes de configuração,
default de auto-aprovação e capacidades de cliente anunciadas) precisam de
decisão humana registrada. Nada em `elixir/lib/**` foi alterado por esta análise.
