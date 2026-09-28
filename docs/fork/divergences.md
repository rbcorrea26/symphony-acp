# Divergências do fork em relação ao upstream

Registro obrigatório de **todo** arquivo alterado em relação a
`upstream/main`. Serve como auditoria do diff mínimo
([README.md](README.md) §3) e como aviso para quem sincroniza
([upstream-sync.md](upstream-sync.md) §4).

Base do registro: `upstream/main` = `be10a1b79df723d6d7612b5651c8522704dafb2e`
(posterior à tag v0.0.3, que aponta para `1c0fb6c8e8ef9031a2c861e62af5f9e66cee39cb`).
As divergências da carta do fork foram introduzidas pela
[PR #1](https://github.com/rbcorrea26/symphony-acp/pull/1); as da análise
arquitetural e dos ADRs entram pela PR documental que trouxe
[acp-analysis.md](acp-analysis.md) e
[adr/0001](adr/0001-executor-abstraction.md)/[adr/0002](adr/0002-acp-protocol-mapping.md).
Arquivos **não** listados abaixo são idênticos à base registrada e
seguem a documentação upstream como autoridade.

## Divergências atuais

| Arquivo | Tipo | Motivo | Comportamento upstream afetado? |
|---|---|---|---|
| `docs/fork/README.md` | novo | carta do fork: remotes, diff mínimo, fronteira de autoridade | não |
| `docs/fork/upstream-sync.md` | novo | procedimento de sincronização com o upstream | não |
| `docs/fork/divergences.md` | novo | este registro | não |
| `docs/fork/adr/README.md` | novo | namespace de ADR do fork e índice dos ADRs | não |
| `docs/fork/adr/0001-executor-abstraction.md` | novo | decisão proposta da abstração de executor (ADR-0001 do fork) | não |
| `docs/fork/adr/0002-acp-protocol-mapping.md` | novo | decisão proposta do mapeamento ACP (ADR-0002 do fork) | não |
| `docs/fork/acp-analysis.md` | novo | análise Codex App Server ↔ ACP: estado do código, especificação oficial do ACP, matriz de mapeamento, gaps, opções de abstração e decisões humanas Q1–Q10 | não |
| `AGENTS.md` (raiz) | novo | contrato de agentes no fork; regras de código continuam em `elixir/AGENTS.md` | não |
| `README.md` | alterado (ponteiro) | indicar que este repositório é um fork e onde está sua documentação | não |

Nenhum arquivo de `elixir/**` foi alterado. A análise é documental: ela **não**
cria executor ACP, adapter, fake, dependência, chave de configuração executável
nem qualquer alteração de comportamento.

## Regras do registro

- Toda alteração em arquivo existente do upstream entra aqui **no mesmo PR**,
  com motivo ligado ao objetivo do fork (abstração de executor / ACP).
- Mudança que afeta comportamento upstream exige:
  1. nota explícita na coluna "comportamento upstream afetado";
  2. atualização da documentação upstream correspondente **no mesmo PR** (o
     upstream exige isso em `elixir/AGENTS.md`); e
  3. ADR no fork quando a mudança for de arquitetura.
- Divergência sem motivo registrado é considerada defeito do fork.

## Não-divergências (deliberadas)

| Assunto | Onde vive | Por que não aqui |
|---|---|---|
| arquitetura do pipeline, ADRs da plataforma, roadmap, runtime/segurança | `rbcorrea26/agentic-dev-environment` | decisão da plataforma, não do Symphony |
| contrato de projeto consumidor (`AGENTS.md`, `WORKFLOW.md`, templates, preflight) | `rbcorrea26/agentic-project-template` | contrato do projeto, não do executor |
| comportamento upstream não alterado | `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, `elixir/AGENTS.md`, `elixir/docs/*` | documentação upstream continua autoritativa |
