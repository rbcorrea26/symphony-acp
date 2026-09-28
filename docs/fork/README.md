# Documentação do fork (`symphony-acp`)

Este diretório concentra a **documentação específica do fork**, acompanhada
pelo contrato `AGENTS.md` na raiz e pelo aviso no `README.md` principal.
Tudo que não foi modificado pelo fork continua sendo documentado — e
autoritativamente — pelo upstream `openai/symphony`.

## 1. O que este fork é

`rbcorrea26/symphony-acp` é um fork de `openai/symphony` cujo único objetivo é
ser o **executor/control plane do pipeline agêntico** da plataforma
`rbcorrea26/agentic-dev-environment`:

- adicionar uma **abstração de executor** ao Symphony;
- implementar o **mapeamento Codex App Server ↔ ACP** (Agent Client Protocol);
- permanecer compatível com o upstream, com **diff mínimo** e explicado.

Neste momento o fork contém **apenas documentação**: nenhuma linha de código foi
alterada em relação ao upstream. A análise arquitetural do caminho Codex App
Server ↔ ACP está **concluída** em [acp-analysis.md](acp-analysis.md) (matriz
`D1`–`D33`, fontes oficiais, opções de abstração, segurança e decisões Q1–Q10) e
as decisões derivadas estão **aceitas** em
[adr/0001](adr/0001-executor-abstraction.md) (abstração de executor) e
[adr/0002](adr/0002-acp-protocol-mapping.md) (mapeamento de protocolo). **Não há
decisão humana aberta bloqueando a fase 3**, e a **implementação não foi
iniciada**: nenhum executor ACP, adapter, fake ou dependência existe no
repositório, e o caminho Codex app-server permanece intacto. O próximo passo é o
executor ACP **fake determinístico**; Cline entra só na fase 4 e DeepSeek depois
dele.

## 2. Relação `origin` / `upstream`

| Remote | URL | Papel |
|---|---|---|
| `origin` | `https://github.com/rbcorrea26/symphony-acp` | nosso fork: branches de trabalho e PRs deste projeto |
| `upstream` | `https://github.com/openai/symphony` | fonte do código upstream; **somente leitura** |

Regras:

- **nunca** empurrar para `upstream` (nem branches, nem tags, nem `main`);
- `main` é a versão integrada do fork: upstream mais alterações próprias
  revisadas por PR. `upstream/main` permanece a referência original;
- trabalho e sincronização usam branches dedicadas a partir de `origin/main`;
  atualizações upstream entram por merge e PR, preservando a ancestralidade
  e os commits do fork, sem rebase de histórico publicado nem force-push;
- base registrada deste marco: `be10a1b79df723d6d7612b5651c8522704dafb2e`
  (`upstream/main` consultado em 2026-09-27), registrada em
  `agentic-dev-environment/manifests/tool-versions.txt` (`symphony-base`).
  A tag `v0.0.3` aponta para `1c0fb6c8e8ef9031a2c861e62af5f9e66cee39cb`,
  anterior à base. `symphony-fork` registra separadamente a revisão integrada do fork.

Configuração segura dos remotes (evita push acidental no upstream):

```bash
git remote -v
git remote set-url --push upstream DISABLED   # opcional, recomendado
```

Procedimento de sincronização: [upstream-sync.md](upstream-sync.md).
Registro das divergências atuais: [divergences.md](divergences.md).

## 3. Política de diff mínimo

1. **Extensão, não reescrita.** O fork adiciona o caminho ACP; o caminho existente
   (Codex app-server) **continua suportado** e não é removido.
2. **Sem refatoração oportunista.** Não renomeie, reformate nem reorganize código
   upstream por proximidade; cada mudança precisa de motivo ligado ao objetivo do
   fork.
3. **Sem cópia de documentação upstream.** Exceto pelo aviso no `README.md`,
   os documentos `SPEC.md`,
   `elixir/README.md`, `elixir/WORKFLOW.md`, `elixir/AGENTS.md`,
   `elixir/docs/*` e `.github/*` permanecem como no upstream; quando o fork
   alterar comportamento, a **divergência** é registrada aqui e o documento
   upstream é citado, não duplicado.
4. **Commits identificáveis e pequenos**: um assunto por commit, sem misturar
   sincronização do upstream com trabalho do fork.
5. **Divergência é dívida registrada.** Toda alteração em arquivo existente do
   upstream entra em [divergences.md](divergences.md) com motivo, arquivo e PR.
6. **Licença preservada.** `LICENSE` (Apache-2.0) e `NOTICE` (Copyright 2025
   OpenAI) permanecem intactos; o fork mantém a atribuição.
7. **Qualidade upstream.** Os gates do upstream (`make all` em `elixir/`,
   `mix specs.check`, `mix pr_body.check`) valem para o fork.

## 4. Fronteira de autoridade (o que é documentado onde)

| Assunto | Documento autoritativo |
|---|---|
| comportamento upstream não alterado (orquestração, workspace, tracker, logging, token accounting) | upstream: `SPEC.md`, `elixir/README.md`, `elixir/AGENTS.md`, `elixir/docs/*` |
| arquitetura e fluxo do pipeline (issue → `ready-for-human`), ADRs da plataforma, roadmap, ambiente/runtime/segurança | `rbcorrea26/agentic-dev-environment` (`docs/architecture/*`) |
| contrato de projeto consumidor (`AGENTS.md`, `WORKFLOW.md`, templates, preflight) | `rbcorrea26/agentic-project-template` |
| extensões do fork: abstração de executor, mapeamento Codex ↔ ACP, análise técnica, divergências | **este diretório** (`acp-analysis.md`, `adr/0001`, `adr/0002`, `divergences.md`) |

**Decisões da plataforma não pertencem a este repositório.** Se uma decisão
(qual executor, qual modelo, quais gates, isolamento de runtime) precisar mudar,
ela muda no `agentic-dev-environment` com ADR novo; aqui só vive o que é
específico do Symphony e do protocolo.

## 5. ADRs do fork

O fork tem namespace de ADR próprio: [adr/README.md](adr/README.md) (numerados
`docs/fork/adr/NNNN-*`). O ADR `0002` **daqui** não é o `0002` da plataforma.
