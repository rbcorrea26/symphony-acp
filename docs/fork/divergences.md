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

A **fase 7b** (ciclo de vida sob demanda, ADR-0009 da plataforma) entra pela branch
`feat/phase7b-on-demand-lifecycle` e é a primeira extensão do fork que muda o
**comportamento do processo** sem alterar o fluxo upstream por omissão: as flags
`--exit-when-idle`, `--issue <id>`, `--resume-only` e `--max-runtime-seconds <n>` são
aditivas e o encerramento é gracioso (nunca `kill`). Arquivos:

| Arquivo | Tipo | Motivo | Comportamento upstream afetado? |
|---|---|---|---|
| `docs/fork/lifecycle.md` | novo | contrato operacional do modo sob demanda (flags, códigos de saída, `resume-only`, o que segue pendente) | não |
| `elixir/lib/symphony_elixir/shutdown.ex` | novo | ponto único de encerramento gracioso com código de saída significativo (injetável em teste); registra o código pedido antes de parar a VM | não |
| `elixir/lib/symphony_elixir/cli.ex` | alterado (aditivo) | quatro flags novas publicadas no ambiente da aplicação; o encerramento usa o código registrado pelo ciclo quando existe e mantém o mapeamento residente quando não existe | não (residente idêntico) |
| `elixir/lib/symphony_elixir/orchestrator.ex` | alterado | ciclo de poll informa se havia algo despachável (para decidir o idle), filtro `--issue` e teto `--max-runtime-seconds` como prazo (o próximo ciclo é agendado no vencimento, o ciclo vencido não despacha trabalho novo e idle comprovado vence o teto) | **sim, mínimo**: só quando as flags são usadas; `maybe_dispatch/1` passa a devolver `{state, resultado}` |
| `elixir/lib/symphony_elixir/agent_runner.ex` | alterado (aditivo) | `--resume-only` pula os turnos do agente e mantém a etapa de entrega | não |
| `elixir/test/symphony_elixir/on_demand_test.exs` | novo | suíte determinística e offline do lifecycle (tracker `memory` + shutdown injetado) | não |

O código de saída é decidido no ciclo e **preservado até o fim do processo**: `Shutdown.request/2`
registra o código antes de pedir a parada graciosa e a CLI (`wait_for_shutdown/0`) usa esse
registro quando a árvore de supervisão cai (`:shutdown`) — sem ele, o encerramento sob demanda
herdaria o default residente (`1`) e o dispatcher leria falha onde houve ciclo concluído. Sem
flag sob demanda não há registro e o mapeamento residente do upstream continua intacto. O teto
é um prazo: o ciclo seguinte é agendado no vencimento dele, um ciclo que já venceu não despacha
trabalho novo e um ciclo comprovadamente idle encerra com `0` (não `3`).

O **bloco D da fase 7b** (contrato de aceite legível por máquina, issue
[#12](https://github.com/rbcorrea26/symphony-acp/issues/12), ADR-0009 §4–§5 da plataforma) entra
pela branch `feat/phase7b-acceptance-contract` e é a primeira extensão do fork que acrescenta
uma **camada de verificação** ao estágio de entrega: o aceite da issue
(`pipeline_contract` v1: escopo `strict`/`advisory`, evidências nomeadas e proibições) passa a
rodar antes de qualquer publicação, **separado** dos gates do repositório e do CI, com
veredicto estruturado (findings de código estável) persistido no comentário de handoff. A
**fase 7b continua incompleta**: a review (`waiting-review`/`rework`, #13) e o architect runner
(#14) não existem ainda. Sobre esse bloco caíram três achados da review do candidato
`ad10879`, fechados no mesmo PR: (1) a retomada de um candidato publicado passou a
**recalcular o aceite sobre o candidato lido do Git** — change set contra a merge base com a
branch base, linhas adicionadas do mesmo diff e evidências do contrato **em vigor** — em vez
de tratar workspace limpo como `not_applicable`; (2) o parser de fence passou a exigir cerca
de fechamento do mesmo marcador, com comprimento ≥ o da abertura e **nada além de espaços**
depois do marcador, para uma pseudo-cerca (` ```not-a-close `) não truncar o YAML; (3) o parse
do change set passou a ser **incremental e bounded enquanto lê** (um campo NUL-delimited por
vez, parando na primeira entrada acima do cap de 5 000), sem materializar a lista inteira
antes do limite.

Sobre o mesmo bloco caíram **quatro achados materiais** da review independente do candidato
`75791b4`, fechados nesta PR: (1) a **cerca** do bloco passou a respeitar o limite estrutural
do CommonMark — no máximo três espaços de indentação (quatro ou mais é código indentado e não
abre nem fecha), contados **só em espaços**, então um marcador com tab é conteúdo e não
trunca o YAML; (2) a **dica textual** do parser deixou de poder apagar uma declaração real:
um bloco **ilegível** passou a ser julgado no texto **bruto** (nada blankado, então nenhuma
heurística de scalar pode esconder nada) e um bloco **legível que não lê a chave** passou a
ser julgado no que o **decoder leu** (uma chave lida que contém o token — um scalar
malformado que absorveu a declaração seguinte, ou uma declaração aninhada — reprova, e um
token dentro de um valor segue sendo dado, não declaração; o blanking de scalar sobrevive
só para a recusa de âncora e o cap, com aspas/comentário começando onde um nó pode começar
e uma citação que não fecha não blankando as linhas seguintes); (3) o **veredicto** persistido
deixou de ser idempotente só pelo SHA do candidato: o comentário autoritativo agora leva a
impressão digital do payload (`<!-- acceptance:result:<sha>:<fingerprint> -->`), o mesmo
candidato com veredicto diferente **substitui** o comentário
(`GitHub.upsert_comment/5`/`update_comment/3`) e falha de escrita continua impedindo os
rótulos; (4) o **sujeito do aceite passou a ser o candidato efetivo** — o diff da base para o
**estado final do workspace** (`Git.effective_change_set/2`: candidato commitado + alterações
do worktree + não rastreados), nunca a escolha entre "worktree" e "candidato", que esquecia
a parte já commitada numa retomada cujo gates só acrescentou um arquivo.

Sobre o mesmo bloco caiu um achado de **fail-open** da revisão de aceite do architect no
candidato `e1b62c4`, fechado nesta PR: `not_applicable` era decidido pelo **change set efetivo
vazio**, o que confundia duas perguntas — "existe sujeito a promover?" e "o change set efetivo
está vazio?". Num workspace com candidato publicado cujo worktree **desfaz por inteiro** o
candidato, o change set efetivo é vazio (a árvore final coincide com a base) e o worktree está
sujo com `HEAD` ≠ base: o run publicaria um novo commit (o revert) e o aceite era declarado
`not_applicable`, deixando de produzir `expected_path_missing`, de executar as evidências
exigidas e de bloquear em `strict`. O sujeito passou a ser decidido por **fatos do git e do
worktree** — `HEAD` ≠ base (merge base com a branch base) **ou** change set efetivo com
entradas, os dois lidos no mesmo passo —, então o escopo e a evidência usam a mesma noção, o
change set final vazio continua vazio (nenhuma entrada é inventada) e o commit que desfaz o
candidato é avaliado pelo contrato em vigor.

Sobre o mesmo bloco caiu um segundo achado de **fail-open** da revisão de aceite do architect no
candidato `376830d`, fechado nesta PR: a decisão entre **criar** e **reconciliar** o candidato era
lida de `git status --porcelain`, que obedece à configuração pessoal `status.showUntrackedFiles=no`.
Com essa configuração, o worktree de um candidato já publicado que ganhou um path **não rastreado** —
exatamente o que o aceite lê de forma explícita (`ls-files --others`, que a configuração não afeta) —
aparecia **limpo**: o aceite podia `PASS` sobre o path, a promoção reconciliava o candidato antigo e o
veredicto ficava associado a um SHA que **não continha o conteúdo aceito**, violando o invariante
central do bloco (o conteúdo aceito é o conteúdo promovido). `Git.status/1` passou a ler
`git status --porcelain --untracked-files=all` — explícito, então independe da configuração pessoal, e
com os arquivos ignorados continuando invisíveis exatamente como `git add -A` os pula —, e a saída
passou a ser lida **crua**: `changed_paths/1` parseia `XY PATH`, cujo campo de status começa com
espaço numa alteração só do worktree (` D answer.sh`), então o `trim` da saída inteira comia o
primeiro caractere do primeiro path. A revisão adversarial do mesmo ciclo mediu ainda aliases
(`alias.status` não sobrepõe o builtin), `diff.ignoreSubmodules` e `submodule.<name>.ignore`
(coerentes com `git add -A`, inclusive os ignores), arquivos ignorados, `core.quotePath` (afeta o
**texto** dos paths do porcelain v1, nunca a detecção), repositório aninhado sem commit
(`git add -A` falha → run falha fechado) e `add.ignoreErrors` (exit ≠ 0 → falha fechada) — nenhum
outro produz divergência entre o que o aceite considera publicado e o que a promoção publica.

Arquivos:

| Arquivo | Tipo | Motivo | Comportamento upstream afetado? |
|---|---|---|---|
| `docs/fork/adr/0006-acceptance-contract.md` | novo | decisão durável: schema v1, política `strict`/`advisory`, veredicto estruturado, evidência nomeada, o que é verificável e o que não é, segurança; §1 revisado para a cerca (três espaços, só espaços) e para a dica textual que nunca esconde uma declaração; §5 revisado para o **candidato efetivo** (o que o run vai promover), para a separação entre "há sujeito" e "change set efetivo vazio" na semântica de `not_applicable` e §8 para o comentário autoritativo do veredicto com impressão digital | não |
| `docs/fork/acceptance-contract.md` | novo | documento operacional do aceite: schema, semântica por caso de diff, semântica de `not_applicable` (sujeito a promover, não "change set efetivo vazio"), tabela de códigos, limites declarados (§6.1 descreve a retomada sobre o candidato efetivo e os quatro casos de sujeito, §8 o artefato autoritativo do veredicto), ponteiros para #13/#14 | não |
| `elixir/lib/symphony_elixir/pipeline_contract.ex` | novo | parser/schema do `pipeline_contract` (data da issue, nunca código; presença/duplicidade da chave contadas nos **nós do parser** — com `maps_as_keywords`, antes do colapso de duplicatas —; a dica textual só **amplia o conjunto de falhas** e nunca esconde uma declaração: um bloco **ilegível** é julgado no texto **bruto** (nada blankado) e um bloco **legível sem a chave** é julgado no que o **decoder leu** (uma chave lida que contém o token — scalar malformado que absorveu a declaração, ou declaração aninhada — reprova; token dentro de um valor não é chave e segue ausente); o blanking de scalar sobrevive só para a recusa de âncora e o cap, com aspas/comentário começando onde um nó pode começar (nunca colado a um `:`) e uma citação que não fecha não blankando as linhas seguintes; chave com aspas é desquotada antes; âncora de nome não-ASCII recusada sem parse; cerca exige **o mesmo marcador**, comprimento ≥ o da abertura, **nada além de espaços** depois do marcador e no máximo **três espaços** de indentação — só espaços, tab é conteúdo —, então ` ```not-a-close ` e uma cerca indentada por quatro espaços são conteúdo e não truncam o bloco; padrão não-UTF-8 recusado), globs compilados uma vez por avaliação com match Unicode, achados puros de escopo/proibição e o struct `Finding` | não (só existe com `delivery.enabled`) |
| `elixir/lib/symphony_elixir/delivery/acceptance.ex` | novo | gate impuro do aceite: deriva o **sujeito** do ciclo como o **candidato efetivo** — o diff da merge base com `base_branch` para o **estado final do workspace** (candidato commitado + worktree + não rastreados), nunca a escolha entre worktree e candidato —, decide `not_applicable` por **existência de sujeito** (`HEAD` ≠ merge base **ou** change set efetivo com entradas, os dois fatos numa leitura só) e **não** por "change set efetivo vazio", roda as evidências exigidas sempre que há sujeito a promover (escopo e evidência usam a mesma noção), decide por modo, descreve/persiste o veredicto com payload limitado por construção (16 KiB, campo `omitted`), calcula a **impressão digital** do payload e monta a marcação `<!-- acceptance:result:<sha>:<fingerprint> -->` e o bloco JSON; varredura de proibição truncada vira o finding `prohibition_scan_truncated` (fail-closed em `strict`) além do limite declarado | não (só existe com `delivery.enabled`) |
| `elixir/lib/symphony_elixir/delivery/acceptance/result.ex` | novo | `Result`: status, `contract_version`, `mode`, findings, evidências, change set e `limits` (serializável em JSON) | não |
| `elixir/lib/symphony_elixir/delivery/gates.ex` | novo | runner único de comando com timeout, compartilhado por gates e evidências (extraído do `delivery.ex`) | não |
| `elixir/lib/symphony_elixir/delivery.ex` | alterado (aditivo) | ordem das três camadas (aceite → gates → evidências), `contract` no resultado, linha + bloco JSON do aceite no comentário de handoff, `run_gates` delegando a `Delivery.Gates` e o candidato amarrado ao SHA aceito nos dois modos (`-created` e `-reconciliado`, cujo candidato é o HEAD local): `delivery_candidate_replaced` se o head da branch não for o aceito; o aceite recebe `delivery.base_branch` para derivar o candidato efetivo; o handoff **cria ou substitui** o comentário autoritativo do candidato (`GitHub.upsert_comment/5`, identidade pelo SHA + impressão digital do payload) antes de mover rótulo | não (sem o bloco `delivery` o caminho é o upstream) |
| `elixir/lib/symphony_elixir/delivery/git.ex` | alterado (aditivo) | `effective_change_set/2` (o **candidato efetivo**: diff da base para o estado final do workspace, `--name-status -z` com rename = destino + origem como deleção, copy = só o destino — no formato da origem vem **antes** do destino —, mais os não rastreados de `ls-files`, sem repetir um path já reportado), `change_entries/1` (parse puro do formato, incremental: um campo NUL-delimited por vez, parada na primeira entrada acima do cap, sem materializar a lista inteira antes), `merge_base/2`, `added_lines/2` (leitura limitada do `git diff` de uma revisão, cujo filho é encerrado no cap, parse com estado de hunk — `+++ b/` só fora de hunk —, + não rastreados limitados: symlink/diretório/dispositivo são pulados por decisão, arquivo regular ilegível é buraco no scan e declara truncamento), `head_sha/1` e leitura crua de saída do git; `status/1` (a leitura que decide **criar vs reconciliar**) passou a rodar `git status --porcelain --untracked-files=all` com a saída **crua** — explícito para não depender de `status.showUntrackedFiles` pessoal e coerente com `git add -A` (ignorados continuam invisíveis), e sem `trim` porque `changed_paths/1` parseia `XY PATH`, cujo campo de status começa com espaço numa alteração só do worktree | não |
| `elixir/lib/symphony_elixir/delivery/github.ex` | alterado (aditivo) | `upsert_comment/5` (identidade do artefato + marcador do payload corrente: cria, mantém quando a impressão digital confere e **substitui** quando o veredicto do mesmo candidato mudou) e `update_comment/3` (`PATCH /issues/comments/:id`), além da superfície REST do estágio | não |
| `elixir/lib/symphony_elixir/config/schema.ex` | alterado (aditivo) | campo `delivery.evidence` (nome → comando) com validação de nome/comando não vazios | não (default `{}`) |
| `elixir/test/symphony_elixir/pipeline_contract_test.exs` | novo | schema, estilo de chave (plana/aspas simples e duplas/tag/explícita) e duplicidade mista, menção da chave dentro de scalar, block scalar e aspas escapadas, âncora (nome não-ASCII incluso) antes da chave, padrão não-UTF-8, **fence** (pseudo-cerca e info string dentro do bloco não fecham, fechamento menor que a abertura não fecha, fechamento com espaços fecha, declaração depois da pseudo-cerca é ambígua, indentação de quatro espaços e tab não abrem nem fecham — com o par de controle de três espaços fechando), **dica textual** (`foo:'unterminated` e o equivalente com aspas duplas falham fechadas, citação válida multi-linha e comentário não declaram, bloco decodificável que não lê a chave declara `:missing_pipeline_contract_key`, prosa sem contrato segue ausente), glob em escala e proibições do parser | não |
| `elixir/test/symphony_elixir/delivery_acceptance_test.exs` | novo | gate sobre git real (change set, rename como deleção, evidências, resume, limites, symlink/binário/arquivo ilegível, varredura truncada falhando fechada, linha que imita cabeçalho de diff, JSON), o **candidato efetivo** (candidato publicado com workspace limpo; retomada com worktree sujo: artefato do gates aceito junto do candidato, artefato não autorizado sem perder o candidato, arquivo alterado de novo reportado uma vez, alteração desfeita no worktree, rename do candidato + deleção posterior, evidência verde/vermelha, contrato endurecido depois da publicação, proibição no diff do candidato alterado; base ausente falhando fechada) e o **sujeito do aceite** (na base com worktree limpo → `not_applicable` nas duas fases; candidato publicado com worktree limpo → sujeito; worktree sujo na base → sujeito; worktree que desfaz o candidato por inteiro → não é `not_applicable`, com `expected_path_missing`, evidência executando, `strict` bloqueando, `advisory` preservado e change set efetivo continuando vazio) | não |
| `elixir/test/symphony_elixir/delivery_test.exs` | alterado | casos ponta a ponta: bloqueio `strict`, regressão #64/#65, `advisory` persistido, evidência verde/vermelha, contrato inválido, segundo ciclo, comentário antes dos rótulos, falha de escrita do comentário que não promove a issue, candidato reconciliado com a branch movida e a **retomada** (aceite recalculado do Git, evidência verde e vermelha, evidência nova exigida depois da publicação, contrato materialmente alterado) e o **worktree que desfaz o candidato por inteiro** (o run não publica o revert: `strict` bloqueia com `expected_path_missing`, nada é publicado e o comentário aceito continua o único); o **artefato do veredicto** (retry com o mesmo veredicto não reescreve, mesmo SHA com veredicto diferente substitui o comentário, atualização antes dos rótulos, falha de atualização que não promove); no parser, change set abaixo/no/acima do cap, tail grande não lido e o candidato efetivo (rename, copy, deleção, non-UTF-8 rastreado e não rastreado, base ausente); a **decisão criar vs reconciliar** (não rastreado visível com `status.showUntrackedFiles=no` fazendo o run **criar** e o arquivo estar dentro do SHA promovido, com o `PASS` no SHA que contém o path, a leitura comparada path a path com o `git add -A` real rodado numa cópia do workspace, o arquivo ignorado que não publica nem cria candidato e o worktree realmente limpo reconciliando sob a mesma configuração) | não |
| `elixir/README.md` | alterado | documenta `delivery.evidence`, os findings e os `limits` do aceite, a varredura truncada como falha fechada em `strict`, a contagem da chave no parser, a cerca (mesmo marcador, sem info string no fechamento, indentação máxima de três espaços, tab é conteúdo), a dica textual que só amplia falhas, o parse incremental do change set, o candidato efetivo do aceite, a semântica de `not_applicable` (sujeito a promover, não "change set efetivo vazio"), o comentário autoritativo do veredicto com impressão digital e a **decisão criar vs reconciliar** (leitura explícita do git, independente de configuração pessoal) | não |
| `elixir/WORKFLOW.md` | alterado (aditivo, tudo comentado) | a política de docs de `elixir/AGENTS.md` exige documentar mudança de contrato do workflow: o bloco `delivery` (e o mapa `delivery.evidence` com `repository-gates` reservado) fica exemplificado como comentário, sem ativar nada | não (nenhuma chave é ativada) |
| `docs/fork/delivery-and-promotion.md` | alterado | fluxo com as três camadas, o invariante *conteúdo aceito = conteúdo publicado* na decisão criar vs reconciliar e ponteiro para o documento do aceite | não |
| `docs/fork/lifecycle.md` | alterado | o contrato de aceite deixa de ser pendência; #13/#14 seguem pendentes | não |
| `docs/fork/README.md` | alterado | status da fase 7b (bloco D implementado; 7b **não** concluída) | não |
| `docs/fork/adr/README.md` | alterado | índice do ADR `0006` | não |

Sobre o mesmo bloco caíram **cinco achados** da review do architect no candidato `998b401`
(fechamento aceitando tab, falso truncamento no orçamento exato e três documentos desatualizados),
fechados nesta PR. (1) **HIGH — o fechamento aceitava tab**: `@closing_fence` era `[ \t]*$`, então
` ``` ` seguido de tab fechava o bloco apesar de o contrato documentado dizer "somente espaços".
Agora é ` *$`: tab, espaço+tab, texto, marcador menor e outro marcador são conteúdo, e o bloco
segue aberto. (2) A revisão adjacente provou que isso **não bastava**: com a fence rejeitada dentro
do bloco, a biblioteca YAML **encerra o mapeamento `pipeline_contract`** naquela linha e absorve o
resto como nó de topo — um campo escrito depois era **descartado em silêncio** (medido:
`deploy: true` depois de um fechamento com tab desaparecia do contrato), o que contradiz a promessa
documentada de que uma pseudo-cerca "não esconde os campos que vêm depois". Agora um bloco que
**declara** o contrato e cuja **estrutura** ainda contém uma cerca é recusado
(`{:fence_inside_block, "```"}`): a fronteira do bloco não é a que o autor escreveu, então ele não é
lido como prefixo válido. A decisão lê só a estrutura (scalar e comentário blankados), então uma
cerca dentro de um scalar continua texto, e blocos que **não** declaram o contrato seguem ignorados
— um bloco de código qualquer pode conter cercas. (3) **MEDIUM — falso truncamento no orçamento
exato**: `untracked_lines/3` respondia `truncated: true` sempre que o orçamento de linhas chegava a
zero (cláusula `budget <= 0`), então um candidato com **exatamente** as 2 000 linhas adicionadas e
nada mais a ler era declarado parcial — `prohibition_scan_truncated` em `strict` **bloqueava um
candidato válido**. A resposta passou a ser calculada do **conteúdo**: orçamento esgotado com nada
restante (nenhum arquivo não rastreado, ou só arquivos sem linha) é varredura **completa**; uma
linha além (rastreada ou não) é truncamento. (4) **LOW — doc**: a linha da tabela que descrevia
"`pipeline_contract:` dentro de scalar + bloco indecodificável → scalar blankado / ausência" era da
semântica antiga; o bloco ilegível (e o acima do cap) é julgado no texto **bruto**, então uma
ocorrência em posição de chave **reprova**, mesmo dentro de um scalar. (5) **LOW — doc**: o ADR
ainda dizia que a varredura de proibição usa `git diff HEAD` — hoje ela lê o **candidato efetivo**
(diff da merge base com a branch base contra o estado final do workspace) — e
`docs/fork/delivery-and-promotion.md` ainda citava `ensure_comment` em vez de
`GitHub.upsert_comment/5`. Junto disso, a auditoria de referências encontrou o **mesmo** defeito de
doc no módulo, no ADR e no documento operacional: o blanking de scalar era descrito como valendo
para o **cap de tamanho**, que na verdade é julgado no texto bruto (medido). Testes: matriz de fence
(espaços fecham; tab, espaço+tab, texto, marcador menor, outro marcador e cerca aninhada não fecham
e são recusados; 0–3 espaços abrem e fecham; quatro espaços é conteúdo; scalar e bloco não
declarante não recusam; declarante recusado — com a regressão de que o campo depois da pseudo-cerca
**não** é descartado) e matriz de fronteira do orçamento (N−1, N, N+1, rastreado, não rastreado,
combinado, arquivo vazio, orçamento exato e uma linha além).

Arquivos:

| Arquivo | Tipo | Motivo | Comportamento upstream afetado? |
|---|---|---|---|
| `elixir/lib/symphony_elixir/pipeline_contract.ex` | alterado | `@closing_fence` passa a aceitar **só espaços** depois do marcador (tab, texto, marcador menor e outro marcador são conteúdo) e o bloco que **declara** o contrato e ainda contém uma cerca na **estrutura** é recusado (`{:fence_inside_block, marker}`), em vez de o YAML encerrar o mapeamento ali e descartar os campos seguintes em silêncio; a doc do módulo e os comentários de `claimed?`/`classify` deixam de atribuir o blanking de scalar ao cap de tamanho (o cap é julgado no texto bruto) | não (só existe com `delivery.enabled`) |
| `elixir/lib/symphony_elixir/delivery/git.ex` | alterado | `added_lines/2`/`untracked_lines/3`: `truncated` passa a significar **conteúdo não inspecionado por causa de um limite**, nunca "um limite foi alcançado" — orçamento esgotado com nada restante é varredura completa, e a decisão é calculada do conteúdo (o read para no primeiro arquivo com linha além do orçamento) | não |
| `elixir/test/symphony_elixir/pipeline_contract_test.exs` | alterado | matriz de cerca de fechamento (espaços fecham; tab, espaço+tab, texto, marcador menor, outro marcador e cerca aninhada **não** fecham e o bloco é recusado; 0–3 espaços abrem/fecham; quatro espaços é conteúdo; fence dentro de scalar e em bloco não declarante não recusa; pseudo-cerca não deixa o campo seguinte ser descartado); os três testes antigos que afirmavam o tab como fechamento foram reescritos | não |
| `elixir/test/symphony_elixir/delivery_acceptance_test.exs` | alterado | matriz de fronteira do orçamento de linhas (N−1, N, N+1 com rastreado, não rastreado, combinado, arquivo vazio, orçamento exato com nada restante e uma linha além) e o caso ponta a ponta em que um candidato com **exatamente** 2 000 linhas passa em `strict` sem `change_scan_truncated` | não |
| `docs/fork/acceptance-contract.md` | alterado | tabela: fechamento com **espaços apenas** (tab é conteúdo), nova linha da recusa `fence_inside_block` e a linha do scalar em bloco indecodificável passa a descrever o texto **bruto**; §5 declara o critério de varredura parcial (**conteúdo não inspecionado**, nunca o limite alcançado) e o blanking de scalar deixa de ser atribuído ao cap de tamanho | não |
| `docs/fork/adr/0006-acceptance-contract.md` | alterado | §4 deixa de citar `git diff HEAD`: a varredura lê o **candidato efetivo** (merge base da branch base → estado final do workspace, rastreado + não rastreado, com o diff lido até o cap); revisão do achado 1 (fechamento só com espaços + recusa do bloco que ainda contém cerca); cap de tamanho julgado no texto bruto; critério de truncamento | não |
| `docs/fork/delivery-and-promotion.md` | alterado | `ensure_comment` → `GitHub.upsert_comment/5`, mantendo o invariante de o veredicto legível por máquina ser persistido antes dos rótulos | não |
| `elixir/README.md` | alterado | cerca de fechamento com **espaços apenas** (tab é conteúdo, divergência deliberada do CommonMark), a recusa `fence_inside_block`, o bloco acima do cap julgado no texto bruto e o critério de truncamento por conteúdo não inspecionado | não |

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
