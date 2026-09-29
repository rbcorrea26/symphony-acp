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

Neste momento o fork contém a **extensão de código** em relação ao upstream: os
**dois incrementos da fase 3** — (1) abstração de executor + `executor.kind` +
executor fake determinístico de teste, registrado em
[adr/0003](adr/0003-phase3-executor-abstraction-scope.md), e (2) o **caminho ACP
real** — `SymphonyElixir.ACP.Client`, `SymphonyElixir.Executor.Acp`, `acp.*` e o
agente ACP fake por stdio, registrado em
[adr/0004](adr/0004-acp-client-implementation.md). A análise arquitetural do caminho
Codex App Server ↔ ACP está **concluída** em [acp-analysis.md](acp-analysis.md)
(matriz `D1`–`D33`, fontes oficiais, opções de abstração, segurança e decisões
Q1–Q10) e as decisões derivadas estão **aceitas** em
[adr/0001](adr/0001-executor-abstraction.md) (abstração de executor) e
[adr/0002](adr/0002-acp-protocol-mapping.md) (mapeamento de protocolo). **Não há
decisão humana aberta bloqueando a fase 3**, e o entregável dela — o ciclo de turnos
do Symphony executado por `Executor.Acp` conversando com um agente ACP externo por
stdio — existe e está coberto por teste: **fase 3 = concluída**. O caminho Codex
app-server permanece intacto e continua sendo o default (`Executor.Codex` é delegação
pura). Cline entra só na fase 4 e DeepSeek depois dele; cancelamento gracioso ACP,
`session/load`, elicitation, MCP local e métrica de uso ACP continuam fora de escopo.

**Fase 4 — Cline real como agente ACP: concluída no fork.** O Cline `3.0.65` do runtime
do pipeline foi executado pelo caminho de produção
(`AgentRunner → Executor.Acp → ACP.Client → stdio/JSON-RPC → ~/automation/bin/cline --acp`),
com `initialize`, `session/new`, `session/prompt` e `session/update` reais, `stopReason`
`end_turn`, alteração real em projeto descartável validada de forma determinística
(`bash answer.sh` = `42`) e teardown do processo do agente asserido pelo teste opt-in
`make cline-acp-e2e`. Nenhuma incompatibilidade de protocolo apareceu e **nenhuma
capability nova foi necessária** (o cliente continua anunciando nenhuma). A autenticação
do agente foi feita **manualmente, fora do Symphony**, como decisão da plataforma, e
segue ao dono do ambiente; nada de credencial entrou no repositório, no workflow ou em
log. Duas ressalvas medidas estão registradas em
[cline-acp-integration.md](cline-acp-integration.md): o `--data-dir` do pipeline **não**
isolou credencial/estado do Cline nesta versão (a reconciliação é da plataforma) e o
Cline deixa um *hub daemon* destacado após o turno (comportamento do agente).

**Fase 5 — provedor inicial (DeepSeek): concluída no fork, com turno real pago.** O
mecanismo do provedor no modo ACP foi medido no binário `3.0.65` instalado
(`CLINE_PROVIDER`/`CLINE_MODEL`/`CLINE_API_KEY`; `deepseek` não está nas `authMethods`
do ACP, então a credencial do provedor é entregue ao processo do agente pelo wrapper do
runtime isolado da plataforma) e **nenhuma alteração de código ACP foi necessária**. O
teste opt-in `make cline-deepseek-e2e` foi executado com sucesso (`1 test, 0 failures`)
exigindo, além do turno real, que o registro de sessão do próprio agente no estado
isolado diga `provider == "deepseek"` com o modelo esperado — um turno que caísse em
outro provedor falha em vez de passar. O mecanismo, o resultado e o que ficou fora de
escopo estão em [cline-acp-integration.md](cline-acp-integration.md) §8; a decisão, o
roadmap e o contrato de segredo continuam na plataforma
(`agentic-dev-environment`, ADR-0003) — inclusive o formato `KEY=VALUE` sem aspas, que a
execução real exigiu passar a verificar.

**Fase 6 — estágio de entrega (gates, Draft PR, CI, candidato, handoff): concluída no
fork, com execução real ponta a ponta.** O fork passou a ter
`SymphonyElixir.Delivery`, chamado pelo `AgentRunner` depois dos turnos quando o
workflow do consumidor opta (`delivery.enabled`): gates do projeto no workspace,
branch + Draft PR do pipeline, observação dos check runs do CI, *candidate stable*
derivado do GitHub, review one-shot e handoff (`ready-for-human`) com remoção do
rótulo de entrada. A decisão está em [adr/0005](adr/0005-delivery-stage.md) e o
comportamento, os limites e a evidência medida em
[delivery-and-promotion.md](delivery-and-promotion.md). Nada disso é obrigatório: sem
o bloco `delivery` o comportamento upstream (e o caminho Codex) continua igual.

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

## 5. Rastreamento de trabalho do fork (GitHub Issues)

O fork `rbcorrea26/symphony-acp` tem **GitHub Issues habilitadas
deliberadamente** (o upstream `openai/symphony` mantém Issues desabilitadas — a
configuração foi herdada quando o fork foi criado). O escopo dessas Issues é
**apenas o que é específico deste repositório**:

- bugs e flakes do próprio Symphony/fork (por exemplo, gates instáveis);
- dívidas técnicas registradas nos ADRs desta pasta (nomes internos `codex_*`,
  reuso temporário de `codex.*`, representação de métricas ausentes);
- trabalho de extensão do fork (abstração de executor, caminho ACP,
  sincronização com o upstream).

Limites explícitos:

- **não altera o upstream**: habilitar Issues aqui é configuração local do fork;
  nada é criado, alterado ou enviado em `openai/symphony` (push segue
  `DISABLED`);
- **não substituem as GitHub Issues dos projetos consumidores**: cada projeto
  consumidor mantém o próprio repositório, quadro e Issues;
- **o control plane do pipeline continua sendo as Issues do projeto consumidor**
  (entrada do fluxo aprovado `GitHub Issues → Symphony → …`): Issues do fork
  nunca são fonte de trabalho para o pipeline, não viram dispatch nem workspace;
- Issues do fork **não** são fonte de verdade de decisão durável — decisão
  durável vive em ADR/documento versionado (ver [../../AGENTS.md](../../AGENTS.md)
  §2 e [divergences.md](divergences.md)).

Primeira issue técnica registrada (com teste afetado, evidência e critério de
aceite): [#2 — gate intermitente em `core_test.exs:1062`](https://github.com/rbcorrea26/symphony-acp/issues/2).

## 6. ADRs do fork

O fork tem namespace de ADR próprio: [adr/README.md](adr/README.md) (numerados
`docs/fork/adr/NNNN-*`). O ADR `0002` **daqui** não é o `0002` da plataforma.
