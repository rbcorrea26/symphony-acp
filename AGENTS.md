# AGENTS.md — contrato de agentes neste fork

Este repositório é o fork `rbcorrea26/symphony-acp` de `openai/symphony`.
Regras de **código** do Elixir continuam em [`elixir/AGENTS.md`](elixir/AGENTS.md)
(upstream, autoritativo e não duplicado aqui). Este arquivo cobre o nível do
repositório.

## 1. Leitura obrigatória antes de editar

1. [`docs/fork/README.md`](docs/fork/README.md) — o que o fork é, remotes,
   política de diff mínimo, fronteira de autoridade;
2. [`docs/fork/divergences.md`](docs/fork/divergences.md) — o que já diverge do
   upstream;
3. [`docs/fork/upstream-sync.md`](docs/fork/upstream-sync.md) — como sincronizar;
4. documentação upstream do assunto (`SPEC.md`, `elixir/README.md`,
   `elixir/WORKFLOW.md`, `elixir/AGENTS.md`, `elixir/docs/*`);
5. plataforma, quando a decisão não for só do Symphony:
   `rbcorrea26/agentic-dev-environment` (`docs/architecture/`).

## 2. Regras

- **Explique o diff.** Toda alteração em arquivo do upstream entra em
  `docs/fork/divergences.md` no mesmo PR, com motivo ligado a
  abstração de executor / ACP.
- **Não invente o mapeamento de protocolo.** O mapeamento Codex App Server ↔ ACP
  só pode ser implementado com a análise do código registrada em ADR
  (`docs/fork/adr/`), consultando a especificação oficial do ACP vigente.
- **Codex continua suportado.** ACP é extensão, não substituição: não remova nem
  quebre o caminho `codex app-server` sem decisão registrada.
- **Decisão da plataforma não se decide aqui** (executor inicial, modelo, gates,
  runtime, roadmap). Se surgir necessidade, registre no
  `agentic-dev-environment` e referencie.
- **Não duplique documentação upstream** que não foi modificada.
- **Confira o Git antes de mudar** (`git remote -v`,
  `git rev-parse HEAD`, `git status --short`) e **nunca** empurre para `upstream`.
- Decisão durável descoberta no trabalho entra no mesmo PR (ADR do fork ou
  atualização dos docs de `docs/fork/`).

## 3. Validação

```bash
cd elixir && make all          # format, lint, coverage, dialyzer
cd elixir && mix specs.check   # @spec em todo def publico
cd elixir && mix pr_body.check --file /path/to/pr_body.md
```

O corpo do PR segue [`./.github/pull_request_template.md`](.github/pull_request_template.md)
(upstream) e deve citar as divergências registradas.
