# Divergências do fork em relação ao upstream

Registro obrigatório de **todo** arquivo alterado em relação a
`upstream/main`. Serve como auditoria do diff mínimo
([README.md](README.md) §3) e como aviso para quem sincroniza
([upstream-sync.md](upstream-sync.md) §4).

Base do registro: `upstream/main` = `be10a1b79df723d6d7612b5651c8522704dafb2e`
(posterior à tag v0.0.3, que aponta para `1c0fb6c8e8ef9031a2c861e62af5f9e66cee39cb`).
As divergências da carta do fork foram introduzidas pela
[PR #1](https://github.com/rbcorrea26/symphony-acp/pull/1); as da análise
arquitetural e dos ADRs entraram pela [PR #3](https://github.com/rbcorrea26/symphony-acp/pull/3),
que trouxe [acp-analysis.md](acp-analysis.md) e
[adr/0001](adr/0001-executor-abstraction.md)/[adr/0002](adr/0002-acp-protocol-mapping.md).
As de **implementação** do incremento 1 da fase 3 (abstração de executor,
`executor.kind` e executor fake determinístico de teste) entraram pela PR da branch
`feat/acp-agent-runner`, que também trouxe
[adr/0003](adr/0003-phase3-executor-abstraction-scope.md). As do **incremento 2**
(cliente ACP, executor ACP, `acp.*` e agente ACP fake por stdio) entram pela PR da
branch `feat/acp-executor-fake-agent`, que também trouxe
[adr/0004](adr/0004-acp-client-implementation.md). As da **verificação do Cline real**
(fase 4: teste opt-in de integração, alvo do `Makefile` e
[cline-acp-integration.md](cline-acp-integration.md)) entram pela PR da branch
`feat/cline-acp-integration`, que **não** altera código de produção. O **fechamento da
fase 4** (turno real do Cline já autenticado) entrou na mesma PR como rodada de
documentação — `docs/fork/cline-acp-integration.md`, `docs/fork/README.md`,
`docs/fork/adr/README.md`, `docs/fork/adr/0002-acp-protocol-mapping.md`,
`docs/fork/adr/0004-acp-client-implementation.md`, `elixir/README.md` e o comentário de
módulo de `elixir/test/symphony_elixir/cline_acp_e2e_test.exs` —, registrando o turno
real medido, a dependência de autenticação e as duas ressalvas medidas (o `--data-dir`
do pipeline não isola credencial/estado do Cline nesta versão e o agente deixa um *hub
daemon* destacado após o turno). As da **fase 5** (mecanismo do provedor DeepSeek
medido no Cline `3.0.65`, teste opt-in que exige o provedor pelo registro de sessão do
agente e o **resultado da execução real**, `1 test, 0 failures`, já com
`provider=deepseek`/`model=deepseek-v4-flash`) entram pela branch
`feat/issue-12-deepseek-phase5` e **não** alteram código de
produção: o executor ACP e o cliente ACP seguem intocados — o provedor/credencial são
configuração da plataforma, entregues ao processo do agente pelo wrapper do runtime
isolado. A fragilidade descoberta na execução real (valor de credencial entre aspas) foi
corrigida **na plataforma**, não aqui.

A **fase 6b** (contenção do agente ACP headless, issue
`rbcorrea26/agentic-dev-environment#26`) também pertence à plataforma e **não** adiciona
divergência neste fork: `acp.command` passou a apontar para o wrapper contido
`$HOME/automation/bin/cline-sandboxed --acp`, que monta uma allowlist de filesystem com
bubblewrap. `Executor.Acp`/`ACP.Client` seguem genéricos (lançam o comando configurado,
sem conhecer a sandbox) e nenhum arquivo deste repositório mudou de comportamento — as
mudanças são de documentação (`docs/fork/cline-acp-integration.md`,
`docs/fork/delivery-and-promotion.md`, `docs/fork/README.md` e este registro).
Arquivos **não** listados abaixo são idênticos à base registrada e
seguem a documentação upstream como autoridade.

## Divergências atuais

| Arquivo | Tipo | Motivo | Comportamento upstream afetado? |
|---|---|---|---|
| `docs/fork/README.md` | novo | carta do fork: remotes, diff mínimo, fronteira de autoridade | não |
| `docs/fork/upstream-sync.md` | novo | procedimento de sincronização com o upstream | não |
| `docs/fork/divergences.md` | novo | este registro | não |
| `docs/fork/adr/README.md` | novo | namespace de ADR do fork e índice dos ADRs | não |
| `docs/fork/adr/0001-executor-abstraction.md` | novo | decisão **aceita (implementação pendente)** da abstração de executor (ADR-0001 do fork) | não |
| `docs/fork/adr/0002-acp-protocol-mapping.md` | novo | decisão **aceita (implementação pendente)** do mapeamento ACP (ADR-0002 do fork) | não |
| `docs/fork/acp-analysis.md` | novo | análise Codex App Server ↔ ACP: estado do código, especificação oficial do ACP, matriz de mapeamento, gaps, opções de abstração e decisões humanas Q1–Q10 | não |
| `AGENTS.md` (raiz) | novo | contrato de agentes no fork; regras de código continuam em `elixir/AGENTS.md` | não |
| `README.md` | alterado (ponteiro) | indicar que este repositório é um fork e onde está sua documentação | não |
| `elixir/lib/symphony_elixir/executor.ex` | novo | behaviour do executor + seleção por `executor.kind` (ADR-0001; ver ADR-0003 para o escopo do incremento) | não |
| `elixir/lib/symphony_elixir/executor/codex.ex` | novo | delegação pura para `SymphonyElixir.Codex.AppServer`, preservando o comportamento Codex | não |
| `elixir/test/symphony_elixir/executor_test.exs` | novo | seleção, preflight do kind e paridade da delegação Codex | não |
| `elixir/test/symphony_elixir/executor_fake_test.exs` | novo | executor fake determinístico (só teste, não registrado) e ciclo do `AgentRunner` pela abstração | não |
| `elixir/lib/symphony_elixir/agent_runner.ex` | alterado | as três chamadas do executor passam pela abstração; texto do prompt de continuação neutralizado (Q9); `opts[:executor]` injetável em teste | **sim, mínimo**: mesma política de turnos/hooks/retry e mesmo comportamento observável no caminho Codex |
| `elixir/lib/symphony_elixir/config/schema.ex` | alterado (aditivo) | bloco `executor` com `kind` (default `codex`); nenhuma chave de `codex.*` removida, renomeada ou movida | não |
| `elixir/lib/symphony_elixir/config.ex` | alterado | preflight valida `executor.kind` (`{:unsupported_executor_kind, kind}`) | **sim**: configuração com kind inválido bloqueia dispatch (a chave não existia antes) |
| `elixir/lib/symphony_elixir/orchestrator.ex` | alterado | ramo de log próprio para `{:unsupported_executor_kind, kind}`, em vez de mensagem enganosa de falha de tracker | não (só mensagem de operador) |
| `elixir/README.md` | alterado | documenta `executor.kind` (política de docs de `elixir/AGENTS.md`) | não |
| `elixir/test/support/test_support.exs` | alterado (aditivo) | `executor_kind` opcional no harness (default `nil` ⇒ sem bloco `executor`, mantendo os workflows de teste atuais) | não |
| `docs/fork/adr/0003-phase3-executor-abstraction-scope.md` | novo | escopo do incremento de fase 3, divergências de superfície e o que segue pendente | não |
| `docs/fork/adr/README.md` | alterado | índice com o ADR-0003 | não |
| `docs/fork/README.md` | alterado | status da fase 3 (incremento implementado; cliente ACP pendente) | não |
| `docs/fork/divergences.md` | alterado | este registro | não |
| `docs/fork/adr/0004-acp-client-implementation.md` | novo | incremento 2: cliente ACP, executor ACP, política de permissão fail-closed, identidade sintética de turno, fake ACP por stdio e dívidas | não |
| `elixir/lib/symphony_elixir/acp/client.ex` | novo | cliente ACP mínimo por stdio (`initialize`, `session/new`, `session/prompt`, `session/update`, `session/request_permission`, teardown) | não |
| `elixir/lib/symphony_elixir/executor/acp.ex` | novo | executor ACP atrás do behaviour + preflight de `acp.command` (`{:error, :missing_acp_command}`) | não |
| `elixir/test/symphony_elixir/acp_test.exs` | novo | config ACP, cliente ACP, executor ACP e o teste de ponta a ponta `AgentRunner → Executor.Acp → agente ACP fake por stdio` | não |
| `elixir/lib/symphony_elixir/executor.ex` | alterado | registra `"acp"`; callback **opcional** `validate_config/1`; `validate_config/1` passa a receber o `%Config.Schema{}` completo (preflight precisa do bloco `acp`) | **sim, mínimo**: a assinatura interna do preflight mudou (kind + bloco do executor); o caminho Codex segue `:ok` e a superfície de sessão (`start_session/2`, `run_turn/4`, `stop_session/1`) não mudou |
| `elixir/lib/symphony_elixir/config/schema.ex` | alterado (aditivo) | bloco `acp` com `command` (sem default) e `auto_approve_requests` (default `false`); nada de `codex.*` ou `executor.*` foi removido, renomeado ou movido | não |
| `elixir/lib/symphony_elixir/config.ex` | alterado | preflight passa o settings completo para `Executor.validate_config/1` (necessário para validar `acp.command` sem acoplar `Config` ao ACP) | não (mesmo ponto do preflight já existente) |
| `elixir/test/symphony_elixir/executor_test.exs` | fork alterado | superfície do behaviour (3 callbacks + `validate_config/1` opcional) e nova assinatura do preflight; `for_kind("acp")` agora resolve | não |
| `elixir/lib/symphony_elixir/ssh.ex` | alterado (aditivo) | `start_port/3` aceita `stderr_to_stdout: false`, usado pelo cliente ACP para **não** fundir o `stderr` remoto no canal de protocolo; o default continua `:stderr_to_stdout` (caminho Codex app-server inalterado) | não no default; **sim, deliberado** para quem passa `stderr_to_stdout: false` (hoje só `ACP.Client`) |
| `elixir/test/symphony_elixir/ssh_test.exs` | alterado (aditivo) | dois testes do parâmetro novo: `stderr` remoto fora do port quando solicitado e merge preservado no default | não |
| `elixir/test/support/test_support.exs` | alterado (aditivo) | `acp_command`/`acp_auto_approve_requests` opcionais no harness (default: sem bloco `acp`) | não |
| `elixir/README.md` | alterado | configuração ACP real (`executor.kind: acp`, `acp.command`, `acp.auto_approve_requests`), limites declarados (sem sandbox/capability/cancelamento gracioso) e dependência de teste (`jq`) | não |
| `docs/fork/adr/0001-executor-abstraction.md` | alterado | status: implementado (incrementos 1 e 2) | não |
| `docs/fork/adr/0002-acp-protocol-mapping.md` | alterado | status e §Implementação: mapeamento implementado no incremento 2 | não |
| `docs/fork/acp-analysis.md` | alterado | status: análise concluída e fase 3 implementada (a evidência da análise não foi reescrita) | não |
| `docs/fork/adr/README.md` | alterado | índice com o ADR-0004 e status da fase 3 concluída | não |
| `docs/fork/README.md` | alterado | status: caminho ACP implementado; fase 3 concluída; Cline continua fase 4 | não |
| `docs/fork/divergences.md` | alterado | este registro | não |
| `docs/fork/cline-acp-integration.md` | novo | verificação do **Cline real** como agente ACP: *spike* (erro `-32000` antes da autenticação), turno real medido pelo caminho `AgentRunner → Executor.Acp → ACP.Client → Cline`, efeito determinístico no workspace descartável, `stopReason` `end_turn`, teardown, dependência de autenticação do runtime e ressalvas medidas (isolamento de credencial/estado e hub daemon); fase 4 **concluída** | não |
| `elixir/test/symphony_elixir/cline_acp_e2e_test.exs` | novo | teste **opt-in** de integração real (`AgentRunner → Executor.Acp → ACP.Client → Cline --acp`) em workspace descartável, com validação determinística e verificação de teardown | não |
| `elixir/Makefile` | alterado (aditivo) | alvo `cline-acp-e2e` (opt-in), espelhando o padrão do alvo `e2e` do upstream; `help`/`.PHONY` atualizados | não |
| `elixir/README.md` | alterado (aditivo) | documenta o alvo opt-in `cline-acp-e2e`, as variáveis de ambiente e a dependência de autenticação do runtime isolado | não |

A verificação da fase 4 **não** alterou código de produção: `elixir/lib/**` permanece
exatamente como na revisão integrada da fase 3 (nenhuma capability, método ACP, default
de permissão, caminho de autenticação ou comportamento Codex mudou). O que entrou foi
teste opt-in e documentação — nenhuma incompatibilidade de protocolo foi demonstrada
entre o Cline real e o cliente atual.

Arquivos de `elixir/**` alterados pelo incremento 1 da fase 3: `agent_runner.ex`
(indireção do executor), `config/schema.ex` e `config.ex` (chave `executor.kind` +
preflight), `orchestrator.ex` (log do erro de executor),
`test/support/test_support.exs` (harness) e `README.md` (documentação da chave).
`codex/app_server.ex` permanece idêntico ao upstream, nenhum teste existente foi
alterado e nenhuma dependência nova entrou. O que o incremento 1 **não** faz: cliente
ACP, Cline, DeepSeek, MCP, capabilities `fs`/`terminal`, sandbox ACP, autenticação
ACP, ferramentas de tracker via ACP, token accounting ACP e cancelamento gracioso de
protocolo — registrado em
[adr/0003](adr/0003-phase3-executor-abstraction-scope.md) §Implementação.

Arquivos de `elixir/**` alterados pelo incremento 2: `executor.ex` (kind `acp` +
callback opcional de preflight), `config/schema.ex` (bloco `acp`), `config.ex`
(preflight com settings completo), `ssh.ex` (parâmetro aditivo
`stderr_to_stdout: false` de `start_port/3`, exigido pela separação de streams do ACP),
`test/support/test_support.exs` (harness) e `README.md` (configuração e teste).
`codex/app_server.ex`, `codex/dynamic_tool.ex`, `agent_runner.ex`, `orchestrator.ex`,
`workspace.ex` e `status_dashboard.ex` **não** foram tocados; nenhum teste upstream foi
removido ou enfraquecido (os únicos testes existentes ajustados são
`executor_test.exs`, do fork, e a adição — sem reescrita — de dois casos em
`ssh_test.exs`, exigidos pelo parâmetro novo); nenhuma dependência nova de runtime
entrou — o agente ACP fake de teste usa `bash` e `jq` (já exigido pelo workflow de lint
de PR do próprio repositório).

A separação de `stdout`/`stderr` do caminho ACP (correção registrada em
[adr/0004](adr/0004-acp-client-implementation.md) §4.10) é a razão da divergência em
`ssh.ex`: `stdout` é o único canal de protocolo, então o lançamento ACP não usa
`:stderr_to_stdout` (local) e passa `stderr_to_stdout: false` no `SSH.start_port/3`
(remoto). O `stderr` do agente é herdado pelo nó e permanece observável no sink de
diagnóstico do serviço, sem nunca chegar ao parser JSON-RPC. O caminho Codex mantém o
merge, porque depende dele desde o upstream.

| `elixir/Makefile` | alterado (aditivo) | alvo `cline-deepseek-e2e` (fase 5): o mesmo turno real do `cline-acp-e2e`, exigindo o provedor DeepSeek pelo registro de sessão do agente; pago e opt-in, fora de `make all`/CI | não |
| `elixir/README.md` | alterado | documenta o alvo `cline-deepseek-e2e` e onde o mecanismo do provedor/credencial está registrado | não |
| `elixir/test/symphony_elixir/cline_deepseek_e2e_test.exs` | novo | teste opt-in de integração real com o provedor DeepSeek (fase 5): efeito determinístico + `provider`/`model` do registro de sessão do agente + teardown; nunca autentica em nome do agente e nunca carrega credencial | não |
| `docs/fork/cline-acp-integration.md` | alterado | §8: mecanismo do provedor medido no Cline `3.0.65` (`CLINE_PROVIDER`/`CLINE_MODEL`/`CLINE_API_KEY`, `authMethods` do ACP), evidência do teste opt-in e **resultado da execução real da fase 5** (`1 test, 0 failures`, `provider=deepseek`/`model=deepseek-v4-flash`) | não |
| `docs/fork/README.md` | alterado | status da fase 5 (mecanismo medido, teste opt-in e turno real executado com sucesso) | não |
| `docs/fork/divergences.md` | alterado | este registro | não |
| `docs/fork/adr/0005-delivery-stage.md` | novo | ADR do estágio de entrega (fase 6: gates do consumidor, Draft PR, CI, candidato derivado do GitHub, review one-shot e handoff) | não |
| `docs/fork/delivery-and-promotion.md` | novo | comportamento, configuração, limites declarados e evidência da execução real da fase 6 | não |
| `elixir/lib/symphony_elixir/delivery.ex` | novo | estágio de entrega: gates do consumidor, publicação da branch/Draft PR, observação do CI, candidato, review one-shot e handoff | não |
| `elixir/lib/symphony_elixir/delivery/git.ex` | novo | operações git locais do estágio (status, branch, commit, push com `GIT_ASKPASS` temporário, redação de saída) | não |
| `elixir/lib/symphony_elixir/delivery/github.ex` | novo | superfície REST do estágio (PR, ref, check runs, labels, comentários, review) reusando o cliente do tracker | não |
| `elixir/lib/symphony_elixir/agent_runner.ex` | alterado | chama o estágio de entrega depois dos turnos quando habilitado; erro de entrega é erro do run | não |
| `elixir/lib/symphony_elixir/config/schema.ex` | alterado (aditivo) | bloco `delivery` (default `enabled: false`: comportamento upstream preservado) | não |
| `elixir/lib/symphony_elixir/config.ex` | alterado | preflight do estágio (`Delivery.validate_config/1`) junto dos preflights existentes | não |
| `elixir/lib/symphony_elixir/github/client.ex` | alterado (aditivo) | `connection/1` expõe coordenadas/auth do tracker ao estágio de entrega (mesma resolução de token do polling) | não |
| `elixir/test/support/test_support.exs` | alterado | harness gera os blocos `tracker.provider` e `delivery` | não |
| `elixir/test/symphony_elixir/delivery_test.exs` | novo | testes do estágio (git real contra `origin` bare + stand-in da API), sem rede, GitHub ou credencial | não |
| `elixir/README.md` | alterado | documenta o bloco `delivery` e o estágio de entrega | não |
| `docs/fork/README.md` | alterado | status da fase 6 (estágio de entrega implementado e validado em execução real) | não |
| `docs/fork/adr/README.md` | alterado | índice do ADR `0005` | não |

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
