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

## ADRs previstos (ainda não escritos)

| ADR | Assunto | Status |
|---|---|---|
| `0001` | **executor abstraction**: como o Symphony passa a acessar o executor por uma indireção, mantendo o caminho Codex app-server funcional | **não escrito** — depende de análise do código |
| `0002` | **ACP protocol mapping**: mapeamento entre o protocolo do Codex App Server e o ACP (sessão, turno, streaming, aprovação, entrada do usuário, cancelamento, ferramentas do cliente, timeouts) | **não escrito** — depende de análise do código |

Antes de escrever cada ADR, a análise deve cobrir (no mínimo):

- `SPEC.md` §5.3.6 (`codex`), §10.1–10.7 (agent runner protocol) e §4.1.5–4.1.7
  (sessão, tentativa de execução, retry);
- `elixir/lib/symphony_elixir/agent_runner.ex` (ciclo de turnos por issue);
- `elixir/lib/symphony_elixir/codex/app_server.ex` (sessão, turnos, aprovação,
  ferramentas dinâmicas, sandbox);
- `elixir/lib/symphony_elixir/config/schema.ex` e `elixir/WORKFLOW.md`
  (configuração por workflow);
- a especificação oficial do ACP vigente — registrar **versão/data consultada**
  no ADR, sem copiar a especificação para cá.

## Nada foi decidido ainda

Nenhuma conclusão sobre o mapeamento de protocolo está registrada neste fork: a
decisão da plataforma que autoriza o trabalho é
`agentic-dev-environment/docs/architecture/adr/0002-acp-como-contrato-de-executor.md`
e o executor inicial está em
`.../adr/0003-cline-deepseek-como-executor-inicial.md`. A análise técnica e a
implementação são fases 3–4 do roadmap da plataforma — **não iniciadas**.
