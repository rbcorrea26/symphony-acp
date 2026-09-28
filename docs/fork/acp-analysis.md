# Análise Codex App Server ↔ ACP (fase documental do fork)

- **Status:** análise concluída e **decisões humanas Q1–Q10 incorporadas**;
  implementação **não** iniciada
- **Data:** 2026-09-27 (revisão com as decisões humanas)
- **Base do código analisado:** `origin/main` = `90d9372cdeb2123e4a5f53a7217461d9d579ace1`
  (`Merge pull request #1 from rbcorrea26/docs/fork-charter`)
- **Base upstream registrada:** `upstream/main` = `be10a1b79df723d6d7612b5651c8522704dafb2e`
  (o fork estava `ahead 3 / behind 0` em relação a `upstream/main` na data desta análise)
- **ADRs derivados:** [adr/0001-executor-abstraction.md](adr/0001-executor-abstraction.md)
  (aceito, implementação pendente) e
  [adr/0002-acp-protocol-mapping.md](adr/0002-acp-protocol-mapping.md)
  (aceito, implementação pendente) — **eles são a fonte normativa das decisões**;
  este documento é a evidência
- **Escopo:** nenhuma linha de código foi alterada por esta análise; o caminho
  Codex app-server permanece intacto.

Este documento responde a três perguntas, com base no código real e na
especificação oficial:

1. como o Symphony conversa hoje com o executor (Codex app-server);
2. o que existe (e o que **não** existe) no ACP para cada uma dessas operações;
3. qual é a menor mudança arquitetural que adiciona ACP sem transformar o
   Symphony em outra arquitetura.

O resultado normativo está nos dois ADRs; este arquivo é a evidência.

## 1. Método e fontes

Fontes usadas, nesta ordem de autoridade:

| Fonte | Papel |
|---|---|
| `elixir/lib/**` e `elixir/test/**` deste fork | comportamento real do Symphony (autoritativo) |
| `SPEC.md` do upstream | contrato de orquestração (autoritativo para comportamento) |
| `elixir/README.md`, `elixir/WORKFLOW.md`, `elixir/AGENTS.md`, `elixir/docs/*` | contrato de configuração e convenções upstream |
| especificação oficial do ACP (§3) | contrato de protocolo do executor alternativo |
| `rbcorrea26/agentic-dev-environment` (docs canônicos) | decisões de plataforma já aceitas (referenciadas, não duplicadas) |

Decisões de plataforma assumidas como **já aprovadas** (não reabertas aqui):
Symphony como control plane, ACP como contrato de executor, Cline + DeepSeek
como executor inicial substituível, perfis conceituais `read`/`dev`/`privileged`,
workspace por issue, gates determinísticos, Draft PR, revisão e handoff
(`agentic-dev-environment/docs/architecture/adr/0001..0006`, `pipeline.md`).

Este fork **não** redefine: por que Symphony, por que ACP, qual executor inicial,
política de revisão nem lifecycle do pipeline.

## 2. Estado atual verificado no código (caminho Codex App Server)

### 2.1 `SymphonyElixir.AgentRunner` (`lib/symphony_elixir/agent_runner.ex`)

Responsabilidade: uma tentativa de trabalho por issue (workspace + prompt +
ciclo de turnos). O ponto relevante para a abstração é que ele toca o executor
em **exatamente três chamadas**, com um termo de sessão tratado como opaco:

| Linha | Chamada | Uso |
|---|---|---|
| 92 | `AppServer.start_session(workspace, worker_host: worker_host)` | abre a sessão |
| 96 | `AppServer.stop_session(session)` | fecha a sessão (`after`) |
| 105 | `AppServer.run_turn(session, prompt, issue, on_message: handler)` | um turno |

Do resultado do turno o runner usa apenas um campo (`turn_session[:session_id]`,
linha 110, para log). O resto do runner é política do Symphony, independente de
protocolo: `Workspace.create_for_issue/2` (41), hooks `before_run`/`after_run`
(46, 50), limite `agent.max_turns` (89), prompt inicial vs. prompt de continuação
(142–154) e `continue_with_issue?/2`, que reconsulta o tracker via
`Tracker.fetch_issues_by_ids/1` (156–173).

Eventos vão para o orquestrador por mensagem: `{:codex_worker_update, issue_id,
message}` (66) e `{:worker_runtime_info, issue_id, %{worker_host, workspace_path}}`
(74–81).

### 2.2 `SymphonyElixir.Codex.AppServer` (`lib/symphony_elixir/codex/app_server.ex`)

Cliente JSON-RPC 2.0 delimitado por linha sobre stdio (1071 linhas). Fatos
verificados:

| Aspecto | Implementação atual |
|---|---|
| Ids fixos de request | `@initialize_id 1`, `@thread_start_id 2`, `@turn_start_id 3` |
| Lançamento local | `Port.open({:spawn_executable, bash}, args: ["-lc", command], cd: workspace, env: <unset de segredos do tracker>, line: 1_048_576)`, com `:stderr_to_stdout` |
| Lançamento remoto | `SSH.start_port(worker_host, "cd <workspace> && unset <segredos> && exec <command>")` |
| Initialize | `initialize` com `capabilities.experimentalApi` + `clientInfo`, depois a notificação `initialized` (275–297) |
| Sessão | `thread/start` com `approvalPolicy`, `sandbox`, `cwd`, `dynamicTools` → `thread.id` (314–341) |
| Turno | `turn/start` com `threadId`, `input:[{type:text,text}]`, `cwd`, `title`, `approvalPolicy`, `sandboxPolicy` → `turn.id` (343–366) |
| Streaming | `receive_loop/6` com buffer `{:eol,_}`/`{:noeol,_}`, timeout = `codex.turn_timeout_ms` e `{:exit_status, status}` → `{:error, {:port_exit, status}}` (379–401) |
| Fim de turno | `turn/completed` (sucesso), `turn/failed`, `turn/cancelled` (403–433) |
| Aprovações | `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `execCommandApproval`, `applyPatchApproval`; auto-resposta quando `approval_policy == "never"` (565–585, 622–664, 761–794) |
| Ferramentas do cliente | `item/tool/call` → `DynamicTool.execute/4` → resultado normalizado devolvido ao app-server (587–620) |
| Entrada do usuário | `item/tool/requestUserInput` com heurística de auto-resposta para `mcp_tool_call_approval_*`; `mcpServer/elicitation/request` e `turn/*input_required*` → `{:error, {:turn_input_required, payload}}` (688–708, 796–893, 1035–1070) |
| Timeout de request | `codex.read_timeout_ms` em `await_response/2` → `:response_timeout` (895–937) |
| Mensagens malformadas | linha não-JSON é logada (`log_non_json_stream_line/2`); se começa com `{`, emite `:malformed`; JSON sem `method` vira `:other_message` (448–477, 939–960) |
| Encerramento | `stop_session/1` = `Port.close(port)` (966–980) |
| Metadata | pid do processo filho (`codex_app_server_pid`); `usage` do payload é embutido na mensagem (987–1001) |
| Eventos emitidos | `:session_started`, `:turn_completed`, `:turn_failed`, `:turn_cancelled`, `:notification`, `:other_message`, `:malformed`, `:approval_auto_approved`, `:approval_required`, `:turn_input_required`, `:tool_call_completed`, `:tool_call_failed`, `:unsupported_tool_call`, `:turn_ended_with_error`, `:startup_failed` |



### 2.3 Configuração (`lib/symphony_elixir/config/schema.ex`, `config.ex`, `WORKFLOW.md`)

Bloco `codex` (schema linhas 174–228), defaults verificados:

| Chave | Default | Validação |
|---|---|---|
| `codex.command` | `codex app-server` | obrigatória, não vazia |
| `codex.approval_policy` | `%{"reject" => %{"sandbox_approval" => true, "rules" => true, "mcp_elicitations" => true}}` | string ou map (`StringOrMap`) |
| `codex.thread_sandbox` | `workspace-write` | string |
| `codex.turn_sandbox_policy` | `nil` → derivado: `%{"type" => "workspaceWrite", "writableRoots" => [workspace], "readOnlyAccess" => %{"type" => "fullAccess"}, "networkAccess" => false, ...}` | map pass-through quando explícito |
| `codex.turn_timeout_ms` | `3_600_000` | `> 0` |
| `codex.read_timeout_ms` | `5_000` | `> 0` |
| `codex.stall_timeout_ms` | `300_000` | `>= 0` (`<= 0` desliga) |

Carregamento: front matter de `WORKFLOW.md` → `Workflow`/`WorkflowStore` → Ecto
embedded schema (`Config.Schema.parse/1`), com reload dinâmico obrigatório
(`SPEC.md` §6.2) e preflight que exige `tracker.kind` suportado e
`codex.command` não vazio (`SPEC.md` §6.3). Não existe hoje nenhuma noção de
"selecionar executor": o bloco de configuração é nomeado pelo fornecedor.

### 2.4 Orquestrador: o contrato real que o executor precisa cumprir

O orquestrador não conhece o app-server; ele consome **eventos** (`orchestrator.ex`):

- `{:codex_worker_update, issue_id, %{event: _, timestamp: _}}` (167–186) →
  `integrate_codex_update/2` (1508–1544) atualiza `last_codex_event`,
  `last_codex_timestamp`, `last_codex_message`, `session_id`, `turn_count`, pid
  e tokens. `session_id` só muda quando o evento traz `:session_id` (1546–1550);
  `turn_count` só incrementa em `:session_started` com `session_id` diferente
  (1552–1568);
- **bloqueio por entrada do usuário** é decidido por `last_codex_event in
  [:turn_input_required, :approval_required]`, por `completion.outcome` ou pelo
  método `mcpServer/elicitation/request` do último payload (659–663);
- **stall** usa `codex.stall_timeout_ms` sobre o timestamp da última atividade
  (581–651), com dois desfechos: bloquear a issue (se era input-required) ou
  reiniciar com backoff;
- **retry/backoff** é Symphony-specific e independe do protocolo (1034–1073,
  1093–1131), preservando `worker_host` e `workspace_path`;
- **token accounting** lê caminhos absolutos específicos de Codex
  (`["params","tokenUsage","total"]`, `["params","msg","info","total_token_usage"]`
  e `usage` de `turn/completed`) e só aplica deltas quando os valores são
  inteiros (1688–1795). Sem esses campos os contadores simplesmente não crescem;
- **rate limits** vêm de `rate_limits` no payload (1756–1770);
- **cancelamento** hoje não é protocol-level: `terminate_running_issue/3`
  interrompe a Task do worker (554–579, 723–745), o que fecha o port e derruba o
  subprocesso.

### 2.5 Testes existentes (o que a fase de implementação vai espelhar)

`elixir/test/symphony_elixir/app_server_test.exs` (1631 linhas) não usa Codex
real: escreve um **script shell falso** (`fake-codex`) em diretório temporário e o
aponta em `codex.command`, exercitando streaming, approvals, tool calls,
timeouts, stderr e frames malformados. `test/support/test_support.exs` gera o
`WORKFLOW.md` de teste com todas as chaves `codex_*`. `mix.exs` roda cobertura com
**threshold 100** e mantém `ignore_modules` explícito para `Codex.AppServer`,
`AgentRunner`, `Workspace`, `Orchestrator` etc.

Consequência direta para a fase 3: um executor ACP de teste deve ser um
**processo falso** (script/executável) que fala JSON-RPC por linha, no mesmo
padrão do `fake-codex` — ou a cobertura exige uma entrada nova em
`ignore_modules` (decisão registrada em ADR-0001).

## 3. Especificação ACP consultada

Fonte **oficial** consultada (nenhuma implementação de terceiro foi usada como
norma):

| Item | Valor |
|---|---|
| Documentação oficial | `https://agentclientprotocol.com` (seções `Protocol v1` e `Schema v2 (Draft)`) |
| Repositório oficial | `https://github.com/agentclientprotocol/agent-client-protocol` (Apache-2.0) |
| Data da consulta | 2026-09-27 |
| Versão do protocolo estável no momento da consulta | **1** (inteiro MAJOR, negociado em `initialize.protocolVersion`); v2 existe apenas como **draft** (pré-releases `schema-v2.0.0-alpha.*`) |
| Release de schema v1 mais recente | `schema-v1.23.0` (tag commit `6d08f41`, publicada em 2026-09-18T10:43:47Z; assets `meta.json`, `meta.unstable.json`, `schema.json`, `schema.unstable.json`) |
| Crate Rust de referência | `agent-client-protocol-schema` v1.9.x (artefato do schema; **não** define compatibilidade de wire — a compatibilidade é definida pelo `protocolVersion` negociado) |
| Páginas relevantes lidas | Overview, Initialization, Session Setup, Prompt Turn, Tool Calls, Cancellation, Terminals, File System, Elicitation, Session Modes, Transports, Schema, Updates |

Pontos da spec que sustentam o mapeamento (resumo, sem copiar a spec):

1. **Transporte stdio**: o cliente lança o agente como subprocesso; mensagens
   são JSON-RPC delimitadas por `\n`, sem newline embutido; `stderr` é livre para
   log; o agente **MUST NOT** escrever nada que não seja ACP em `stdout`.
2. **Initialize**: `initialize` obrigatório com `protocolVersion` (versão mais
   recente que o cliente suporta), `clientCapabilities` e `clientInfo`; resposta
   traz `protocolVersion` escolhido, `agentCapabilities`, `agentInfo` e
   `authMethods`. Capacidade omitida é tratada como **UNSUPPORTED**. Se o cliente
   não suporta a versão respondida, deve fechar a conexão.
3. **Sessão**: `session/new` (`cwd` absoluto + `mcpServers`) → `sessionId`;
   opcionais: `session/load` (capability `loadSession`), `session/resume`,
   `session/close`, `session/delete`, `session/list`. Todo caminho no protocolo
   **MUST** ser absoluto.
4. **Turno**: `session/prompt` (`sessionId`, `prompt` como `ContentBlock[]`)
   responde **uma única vez, no fim do turno**, com `stopReason` ∈ {`end_turn`,
   `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`}. Progresso vem por
   notificações `session/update` (`agent_message_chunk`, `agent_thought_chunk`,
   `user_message_chunk`, `tool_call`, `tool_call_update`, `plan`,
   `available_commands_update`, `current_mode_update`, `config_option_update`,
   `session_info_update`, `usage_update`).
5. **Ferramentas**: o agente reporta `tool_call`/`tool_call_update` (kinds
   `read|edit|delete|move|search|execute|think|fetch|switch_mode|other`, status
   `pending|in_progress|completed|failed`). O cliente **não** registra ferramentas
   próprias no agente (não existe equivalente a `dynamicTools` do Codex).
6. **Permissão**: `session/request_permission` (cliente-decidido) com
   `options[].kind` ∈ {`allow_once`, `allow_always`, `reject_once`,
   `reject_always`} e resposta `outcome` ∈ `{selected: optionId, cancelled}`.
7. **Cancelamento**: notificação `session/cancel` (o agente **MUST** responder o
   `session/prompt` original com `stopReason: cancelled`; o cliente **MUST**
   responder pedidos de permissão pendentes com `cancelled`) e, por request,
   `$/cancel_request` (erro JSON-RPC `-32800`).
8. **Capacidades de cliente**: `fs.readTextFile`/`fs.writeTextFile`, `terminal`,
   `elicitation.form`/`elicitation.url`, `auth.terminal`,
   `session.configOptions` — todas **opt-in**, anunciadas na initialize; o agente
   **MUST NOT** chamar método cuja capacidade o cliente não anunciou.
9. **Uso/tokens**: a spec v1 define `usage_update` (uso da janela de contexto e
   custo acumulado), sem o detalhamento por turno que o Codex expõe.

## 4. Matriz de mapeamento

Classificação por dimensão: `1:1` (mesma semântica), `adaptável` (mesma função,
forma diferente), `sem equivalente direto` (gap real), `Symphony-specific`
(existe só no Symphony, não é problema de protocolo), `ACP-specific` (existe só
no ACP). Linhas numeradas (`D1`…`D33`) para citação em
[ADR-0002](adr/0002-acp-protocol-mapping.md).

| # | Dimensão | Symphony/Codex hoje | ACP | Equivalência | Gap | Adaptação necessária |
|---|---|---|---|---|---|---|
| D1 | Criação do processo | `Port.open` → `bash -lc <codex.command>` com `cd` no workspace, `env` saneado (segredos do tracker removidos), `line: 1 MiB`, `:stderr_to_stdout`; remoto via `SSH.start_port` | Cliente lança o agente como subprocesso; `stdio` com JSON-RPC delimitado por `\n`; `stderr` livre para log | adaptável | A spec não define a linha de comando nem o `cwd` do processo (só `session/new.cwd`); não define separação de `stderr` | Reusar o mesmo lançamento (`Port`/`SSH` + comando configurado do executor) e manter o saneamento de env; manter parser tolerante porque `:stderr_to_stdout` mistura log do agente no `stdout` (a spec proíbe isso do lado do agente) |
| D2 | Handshake / initialize | `initialize` (`capabilities.experimentalApi` + `clientInfo`) e notificação `initialized`; ids fixos 1/2/3 | `initialize` com `protocolVersion`, `clientCapabilities`, `clientInfo` → `protocolVersion` escolhido, `agentCapabilities`, `agentInfo`, `authMethods`; sem notificação `initialized` | adaptável | Negociação de versão (o cliente MUST usar a maior que suporta; incompatível ⇒ fechar) e capacidades omitidas = UNSUPPORTED | Novo handshake no executor ACP: enviar `protocolVersion: 1`, anunciar somente capacidades implementadas, validar a versão devolvida e falhar cedo (`{:error, {:acp_version_unsupported, v}}`) |
| D3 | Capabilities | Cliente anuncia `experimentalApi: true`; ferramentas do cliente entram em `thread/start.dynamicTools` | `clientCapabilities` opt-in (`fs`, `terminal`, `elicitation`, `auth.terminal`, `session.configOptions`) + `agentCapabilities` do agente | adaptável | Semântica oposta: no Codex o cliente **oferece** ferramentas; no ACP o cliente **executa** operações pedidas pelo agente | Anunciar o mínimo (proposta inicial: **nenhuma** capacidade de cliente) e registrar cada capacidade anunciada como decisão explícita de privilégio |
| D4 | Autenticação | Nenhuma no protocolo (Codex usa credencial própria no host) | `authenticate` + `authMethods` (incl. tipo `terminal`), capability `auth.logout` | ACP-specific | Symphony não tem caminho para autenticação interativa | Não automatizar (`cline auth` é manual, ADR-0003 da plataforma); `auth_required` deve virar bloqueio/erro registrado, nunca prompt interativo |
| D5 | Criação de thread/session | `thread/start` com `approvalPolicy`, `sandbox`, `cwd`, `dynamicTools` → `thread.id` | `session/new` com `cwd` absoluto + `mcpServers` → `sessionId` | adaptável | ACP não aceita política de aprovação/sandbox na criação; `mcpServers` é um insumo que o caminho Codex não tem | `session/new(cwd: workspace_canonico, mcpServers: [])`; reusar a validação de workspace existente antes de compor o parâmetro |
| D6 | Envio do prompt | `turn/start` (`threadId`, `input:[{type:text,text}]`, `cwd`, `title`, `approvalPolicy`, `sandboxPolicy`) responde imediatamente com `turn.id`; fim do turno é notificação | `session/prompt` (`sessionId`, `prompt: ContentBlock[]`) é uma request de **longa duração**: a resposta só chega no fim do turno | adaptável | Modelo request/response invertido: hoje o Symphony espera resposta rápida do `turn/start` e depois consome notificações; `read_timeout_ms` não pode ser aplicado ao `session/prompt`; ACP não tem `title` | Loop de turno próprio para ACP: registrar o id de `session/prompt` como pendente e continuar consumindo `session/update` até a resposta chegar; timeout por silêncio (`turn_timeout_ms`), não por resposta |

10. **Sandbox**: a spec ACP **não define** sandbox, política de sistema de
    arquivos, rede nem aprovação global — o único mecanismo de controle é
    permissão por chamada de ferramenta (+ modos/config options quando o agente
    oferece). Essa é a lacuna mais relevante desta análise.

> Esta seção resume a spec para justificar o mapeamento; a spec segue sendo a
> autoridade. A fase 3 deve **fixar** a release de schema usada (`schema-v1.23.0`
> ou mais nova, com data e SHA registrados no PR) na implementação.

| D7 | Múltiplos turnos | Mesmo `thread_id` para os turnos de continuação dentro de uma tentativa (`SPEC.md` §10.2); `agent.max_turns` limita | Vários `session/prompt` na mesma `sessionId` | 1:1 | Nenhum | Reutilizar `agent.max_turns` e o prompt de continuação sem mudança de política |
| D8 | Streaming de eventos | `receive_loop` por linha (`eol`/`noeol`), eventos `turn/*`, `item/*` e notificações genéricas; linha não-JSON vai para log | Notificações `session/update` (11 variantes) + requests do agente + resposta final do prompt | adaptável | Cobertura de variantes diferente; o Symphony hoje não interpreta chunks de mensagem | Emitir evento Symphony equivalente para cada `session/update` (ver D9 e D29), mantendo `payload`/`raw` no evento para dashboard e diagnóstico |
| D9 | Mensagens do modelo | Chega como notificação genérica (`:notification`) e é humanizada por `StatusDashboard.humanize_codex_message/1` | `agent_message_chunk`, `agent_thought_chunk`, `user_message_chunk` (agrupáveis por `messageId`) | adaptável | ACP é mais rico (chunks + ids); nenhum dos dois alimenta decisão do orquestrador | Mapear `agent_message_chunk` → evento `:notification` com o payload ACP íntegro (fase 3); evento dedicado de chunk é evolução possível, não requisito |
| D10 | Tool calls (relato) | Notificações `item/*` e pedidos de aprovação; ferramentas do cliente resolvidas no Symphony | `tool_call` / `tool_call_update` (nome, título, `kind`, `status`, `content`, `locations`, `rawInput`/`rawOutput`) | adaptável | O agente ACP executa as ferramentas; o Symphony só observa (salvo `fs.*`/`terminal`, que não serão anunciados) | Mapear para eventos de observabilidade; **não** tentar executar nem bloquear ferramenta do agente, exceto via `session/request_permission` (D13) |
| D11 | Client-side tools | O cliente (Symphony) expõe `dynamicTools`; `item/tool/call` executa no host com auth do tracker e devolve resultado | Não existe registro de ferramenta do cliente; o cliente executa apenas `fs/*` e `terminal/*`, quando anunciados | sem equivalente direto | Ferramentas do tracker (`linear_graphql`, `github_api`, …) não têm canal ACP equivalente | Gap registrado. Caminho futuro possível: expor as ferramentas do tracker como **servidor MCP local** em `session/new.mcpServers` (fase 4+, exige ADR). **Não** anunciar `fs`/`terminal` para contornar isso |
| D12 | Dynamic tools | `thread/start.dynamicTools` + `DynamicTool.bind/execute` (adapter do tracker, com `secret_environment_names`) | Sem equivalente | sem equivalente direto | Mesmo gap de D11, visto pelo lado do Symphony: nenhuma forma de injetar ferramenta própria | Manter `DynamicTool` intacto para Codex; para ACP registrar indisponibilidade (o agente usa as ferramentas que ele já tem) |
| D13 | Approval requests | `approval_policy` (config) + métodos `*/requestApproval`, `execCommandApproval`, `applyPatchApproval`; auto-resposta quando `approval_policy == "never"`; caso contrário `:approval_required` → issue bloqueada | `session/request_permission` com `options[].kind` (`allow_once`, `allow_always`, `reject_once`, `reject_always`) e resposta `outcome` (`selected`/`cancelled`) | adaptável | Não existe política global de aprovação no ACP; a decisão é por chamada; e a spec exige **resposta** ao request | **Decisão Q2:** `acp.auto_approve_requests` com default **`false`** (fail closed) — o cliente responde recusando/bloqueando (`:approval_required` + issue bloqueada), nunca aprova automaticamente; autoaprovação futura é configuração explícita e testada |
| D14 | User input requests | `item/tool/requestUserInput` (+ heurística `mcp_tool_call_approval_*`), `mcpServer/elicitation/request` e `turn/*input_required*` → `:turn_input_required` → issue bloqueada | `elicitation/create` (modos `form` e `url`), capability de cliente opt-in; o agente MUST NOT pedir modo não anunciado | sem equivalente direto | Formato/semântica diferentes (questions/options vs. JSON Schema de formulário e URL out-of-band) | Fase 3: **não** anunciar elicitation; pedidos de input do agente não são atendidos (o agente encerra o turno e o orquestrador trata como conclusão/erro). Adotar `elicitation` é decisão futura com ADR |

| D15 | Sandbox / policy | `thread_sandbox` (`read-only`, `workspace-write`, `danger-full-access`) e `turn_sandbox_policy` (`workspaceWrite`, `writableRoots`, `readOnlyAccess`, `networkAccess`) aplicados pelo Codex | **Sem equivalente**: nenhuma política de sandbox, filesystem ou rede | sem equivalente direto | O ACP não oferece nenhum controle equivalente; o que o agente pode ler/escrever/rede é decisão do agente e do SO | Gap registrado e explícito: para ACP o Symphony **não** promete sandbox. Mitigações são do projeto/plataforma (workspace dedicado, ausência de segredos no env do filho, sem privilégio, Draft PR, gates). Ver §8 |
| D16 | Environment propagation | `Port.open env:` remove nomes de `secret_environment_names`; no remoto, `unset` no comando; `:stderr_to_stdout` | O cliente lança o subprocesso; não há env no `initialize`; `env` existe em `terminal/create` (capacidade de cliente) e em MCP stdio | 1:1 | Nenhum para o lançamento; o risco de vazamento é idêntico ao atual | Reusar exatamente o mesmo saneamento; nunca colocar segredo de modelo/tracker em YAML versionado (só `$VAR`), e não anunciar `terminal` para não abrir canal alternativo de env |
| D17 | Workspace / root | `Workspace.create_for_issue/2` + `validate_workspace_cwd/2` (canonicaliza, exige prefixo do root, rejeita o próprio root e escape por symlink); `cwd` em `thread/start` e `turn/start` | `session/new.cwd` absoluto; `additionalDirectories` é capability opcional (roots extras) | adaptável | A spec exige caminho absoluto, mas não valida nada; `additionalDirectories` ampliaria a raiz se anunciado | Reusar a validação existente e passar o workspace canônico em `session/new`; **não** anunciar `additionalDirectories` |
| D18 | Cancellation | Não é protocol-level: o orquestrador interrompe a Task do worker → port fecha → subprocesso morre; o app-server também mapeia `turn/cancelled` para erro | `session/cancel` (notificação; o agente MUST responder o `session/prompt` com `stopReason: cancelled`), `$/cancel_request` (por request, erro `-32800`), `session/close` | adaptável | O runner atual não tem canal para pedir cancelamento gracioso (a sessão vive dentro do processo da Task) | Fase 3 mantém o cancelamento por interrupção da Task (paridade com Codex) e registra o gap; cancelamento gracioso exige canal novo (mensagem dedicada ao loop do runner) — evolução, não requisito desta fase |
| D19 | Timeout | `read_timeout_ms` (5 s, resposta de request) e `turn_timeout_ms` (1 h, silêncio entre saídas do stream; cada saída reinicia) | O protocolo **não** define timeout; é inteiramente responsabilidade do cliente | adaptável | Definir qual request usa qual timeout; `session/prompt` não pode usar `read_timeout_ms` | `read_timeout_ms` para `initialize`/`session/new` (respostas rápidas); `turn_timeout_ms` como silêncio máximo entre notificações enquanto o `session/prompt` está pendente |
| D20 | Stall detection | `codex.stall_timeout_ms` sobre `last_codex_timestamp`; input-required bloqueia em vez de reiniciar | Sem conceito de stall; se o agente fizer silêncio, nada chega ao cliente | Symphony-specific | Um agente ACP que pensa muito tempo é indistinguível de travado até o timeout (mesmo problema do Codex) | Nenhuma mudança de mecanismo: o campo é lido pelo orquestrador. Registra-se a dívida de nome (`codex.*` governando execução ACP) e a possibilidade de `agent_thought_chunk` servir de heartbeat para reduzir falso positivo |

| D21 | Process crash | `{:exit_status, status}` → `{:error, {:port_exit, status}}` → runner falha → orquestrador agenda retry com backoff | Mesmo modelo: o agente é subprocesso do cliente; a morte é detectada pelo cliente | 1:1 | Nenhum | Nenhuma: o tratamento de saída do port é reusável |
| D22 | Malformed messages | Linha não-JSON é logada; se parece JSON (`{`), emite `:malformed`; JSON sem `method` vira `:other_message`; o waiter de resposta ignora mensagens que não são dela | O agente **MUST NOT** escrever não-ACP em `stdout`; `stderr` é livre | adaptável | A spec é mais estrita que a implementação atual; e `:stderr_to_stdout` viola o framing na prática | Manter o parser tolerante (paridade de comportamento e robustez contra log do agente no `stdout`), logando `:malformed` para diagnóstico; não transformar tolerância em contrato |
| D23 | Retry | Symphony-specific: backoff com `agent.max_retry_backoff_ms`, `delay_type: :continuation` para retomada normal, tentativa preservando `worker_host`/`workspace_path` | Protocolo-agnóstico (nova tentativa ⇒ novo processo e nova `session/new`) | Symphony-specific | Nenhum | Nenhuma mudança: a nova tentativa abre nova sessão ACP, do mesmo modo que hoje abre nova thread |
| D24 | Continuation após retry | Prompt de continuação textual gerado pelo runner, com menção explícita a "Codex" (linhas 144–154 de `agent_runner.ex`); `attempt` interpolado pelo template do `WORKFLOW.md` | Mesma semântica (novo `session/prompt` na mesma sessão, ou sessão nova após retry) | adaptável | Texto de continuação é específico de Codex e viaja para o modelo; com ACP continua tecnicamente válido, mas desatualizado | **Decisão Q9:** neutralizar o texto hardcoded quando a abstração de executor entrar (fase 3, no mesmo PR que troca as 3 chamadas); **não** alterar o prompt nesta PR documental |
| D25 | Session identity | `session_id = "<thread_id>-<turn_id>"` (`SPEC.md` §4.2, §10.2), consumido por logs, dashboard, `turn_count` e bloqueio | Apenas `sessionId`; **não existe** identificador de turno | adaptável | ACP não fornece `turn_id`, e o orquestrador só incrementa `turn_count` quando chega `:session_started` com `session_id` novo (1552–1568) | Compor `session_id = "<sessionId>-<n>"` com `n` = contador local de turno (1-based) e emitir `:session_started` por turno: identificador **interno/sintético do Symphony**, apenas para contadores/logs/dashboard — **não** é turn id do ACP e **nunca** é enviado ao agente |
| D26 | Completion | `turn/completed` ⇒ sucesso; `turn/failed` ⇒ erro; `turn/cancelled` ⇒ erro | Resposta única do `session/prompt` com `stopReason` ∈ {`end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`} | adaptável | Mapear 5 valores de `stopReason` para a taxonomia de erro do Symphony | `end_turn` ⇒ `{:ok, result}`; `cancelled` ⇒ `{:error, {:turn_cancelled, ...}}`; `max_tokens`/`max_turn_requests`/`refusal` ⇒ `{:error, {:turn_failed, %{stop_reason: reason}}}` (paridade: turno não concluído é falha) |
| D27 | Token / accounting / usage | `thread/tokenUsage/updated` e `usage` de `turn/completed`; o orquestrador lê caminhos absolutos e só aplica deltas inteiros | `usage_update` (uso da janela de contexto e custo acumulado) na família `session/update` | adaptável | ACP não expõe o breakdown input/output por turno que o accounting atual espera; o campo pode trazer custo, não tokens | **Não fabricar métrica:** ausência de dado aparece como **indisponível**, nunca como zero "real" (Q6); mapear `usage_update` apenas se os campos forem realmente compatíveis; se o dashboard não souber expressar ausência sem ambiguidade, é dívida a resolver antes da integração real do Cline |
| D28 | Rate limits | `codex_rate_limits` alimentado por `rate_limits` nos payloads | Sem notificação equivalente | sem equivalente direto | Não há rate limit no protocolo | Aceitar ausência: campo fica vazio; nenhuma mudança no orquestrador |

| D29 | Logging / telemetry | `session_id` obrigatório, `last_codex_event`, `last_codex_message`, `codex_app_server_pid`, contadores `codex_*`; dashboard humaniza mensagens; `docs/logging.md` define os campos | Protocolo não define logging; o cliente mantém seus próprios campos | adaptável | Nomes internos são `codex_*`; ACP não fornece pid no protocolo (o cliente conhece o pid do port) | Manter os nomes internos na fase 3 (renomear é refactor amplo e proibido pela política de diff mínimo) e registrar a dívida de nomenclatura; continuar expondo o pid obtido do port |
| D30 | Graceful shutdown | `stop_session/1` = `Port.close` (sem despedida de protocolo) | Não há método de shutdown global; `session/close` encerra uma sessão liberando recursos | adaptável | Não existe sequência de encerramento acordada | **Decisão Q7:** fase 3 usa `Port.close` como **encerramento de processo/transporte** (paridade), explicitamente **não** equivalente a `session/cancel`/`session/close`; cancelamento gracioso fica para a fase de integração real, que deve distinguir lifecycle do processo do lifecycle da sessão ACP |
| D31 | Executor-specific configuration | Bloco `codex.*` (command, approval_policy, thread_sandbox, turn_sandbox_policy, turn/read/stall timeout), normativo em `SPEC.md` §5.3.6/§6.4 | Não há configuração de protocolo; o cliente decide e o agente oferece modos/config options | adaptável | Preflight exige `codex.command` não vazio; nenhum seletor de executor existe | **Decisão Q1:** adicionar `executor.kind` (default `codex`), preservar `codex.*` sem breaking change e criar `acp.*` só para configuração específica do ACP; **não** migrar timeouts genéricos para `executor.*` agora (reuso pelo ACP = dívida registrada). Proposta detalhada em §7 |
| D32 | MCP servers / ferramentas externas | Não há no caminho Codex (ferramentas entram como `dynamicTools`) | `session/new.mcpServers` (stdio/HTTP/SSE) com `mcpCapabilities` do agente | ACP-specific | Symphony não monta nem supervisiona MCP servers hoje | Não implementar nesta fase; registrar como caminho possível para D11/D12 (ferramentas do tracker via MCP local) |
| D33 | Session modes / config options | Sem equivalente (Codex não expõe modos) | `modes` em `session/new`, `session/set_mode`, `current_mode_update`; `session/set_config_option`, `config_option_update` (capability `session.configOptions`) | ACP-specific | Symphony não tem conceito de modo de agente; perfis `read`/`dev`/`privileged` são da plataforma, não do protocolo | Não implementar nesta fase; registrar como possível alavanca futura para aprovação/seleção de perfil (mapear perfil da plataforma → modo do agente), sempre como decisão explícita |

### 4.1 Resumo da matriz

| Classificação | Dimensões |
|---|---|
| `1:1` | D7, D16, D21 |
| `adaptável` | D1, D2, D3, D5, D6, D8, D9, D10, D13, D17, D18, D19, D22, D24, D25, D26, D27, D29, D30, D31 |
| `sem equivalente direto` | D11, D12, D14, D15, D28 |
| `Symphony-specific` | D20, D23 |
| `ACP-specific` | D4, D32, D33 |

Leitura do resumo: o núcleo do ciclo de vida (abrir sessão, mandar prompt,
observar stream, falhar, repetir, encerrar) é `1:1` ou `adaptável`. Os gaps
reais são de **capacidade**: sandbox/política (D15), ferramentas do cliente
(D11/D12), elicitation (D14) e rate limits (D28).


## 5. Gaps mais relevantes, em ordem de impacto

1. **Sandbox/política (D15)** — o Symphony **não consegue impor** no ACP o que
   impõe no Codex (`thread_sandbox`, `turn_sandbox_policy`, `networkAccess`).
   Não há nada no protocolo que substitua. Consequência: para o executor ACP a
   fronteira de escrita/leitura/rede é o que o agente e o SO garantirem. Isso é
   consistente com o que a plataforma já registrou (Cline tem menos garantias
   formais — ADR-0003 do `agentic-dev-environment`) e **não** pode ser
   apresentado como sandbox.
2. **Ferramentas do tracker (D11/D12)** — `dynamicTools` não existe em ACP. Duas
   saídas conhecidas: (a) aceitar que o executor ACP não recebe as ferramentas do
   tracker; (b) expor as ferramentas como MCP local via `session/new.mcpServers`
   (fase 4+, exige ADR). Nenhuma das duas é decidida aqui.
3. **Entrada do usuário / elicitation (D14)** — o Symphony hoje auto-responde
   perguntas específicas do Codex e bloqueia a issue nos demais casos. Em ACP,
   `elicitation/create` só é legítimo se o cliente anunciar o modo; a decisão
   inicial (não anunciar) simplifica e é a mais segura, mas muda a semântica de
   "bloqueado por falta de informação".
4. **Token accounting (D27, Q6)** — o ACP expõe `usage_update` sem o breakdown por
   turno do Codex. **Decisão:** ausência de dado **não** pode virar zero "real";
   representa-se como **indisponível/ausente** e **nunca** se fabrica métrica. Se
   o estado/dashboard atuais não souberem expressar ausência sem ambiguidade, é
   **dívida a resolver antes da integração real do Cline** (fase 4).
5. **Cancelamento gracioso (D18, Q7)** — hoje é kill da Task; o ACP prevê
   `session/cancel`/`session/close`. Gap de arquitetura (não de protocolo): o
   runner não tem canal de cancelamento. **Decisão:** adiado para a fase de
   integração real (≥ 4); a fase 3 mantém o encerramento simples compatível com o
   lifecycle da Task/processo e **não** afirma que `Port.close` equivale a
   `session/cancel` ou a `session/close`.
6. **Dívida de nomenclatura e de configuração (D20/D29/D31)** — `codex.*` e os
   campos internos `codex_*` passariam a governar execução ACP. Manter na fase 3
   (diff mínimo) e registrar como dívida explícita; renomear é refactor amplo.
7. **Modos/config options (D33)** — capacidades ACP que o Symphony não usa hoje e
   que só fazem sentido como decisão de privilégio explícita.


## 6. A menor abstração possível

Pergunta a responder: *qual é a menor mudança arquitetural que permite adicionar
ACP sem transformar o Symphony em uma arquitetura nova?* O ponto de partida é o
fato verificado em §2.1: o `AgentRunner` usa o executor por **três chamadas**.

### Opção A — abstração interna genérica de executor (`Executor` + implementações)

```
AgentRunner ──▶ Executor (behaviour + seleção por configuração)
                 ├── Executor.Codex ──▶ Codex.AppServer (arquivo upstream intacto)
                 └── Executor.Acp    ──▶ cliente ACP (novo)
```

- **Diff**: 1 arquivo upstream alterado (`agent_runner.ex`, ~3 chamadas), 1
  arquivo upstream alterado de forma aditiva (`config/schema.ex`), 3 arquivos
  novos (`executor.ex`, `executor/codex.ex`, `executor/acp.ex`) + testes.
- **Risco de regressão**: baixo — o caminho Codex vira delegação direta
  (`Executor.Codex.start_session/2` = `AppServer.start_session/2`), sem reescrever
  o arquivo upstream.
- **Compatibilidade Codex**: total, inclusive os testes que chamam
  `AppServer.run/4` diretamente.
- **Testes**: o `fake-codex` continua válido; a fase 3 acrescenta um agente ACP
  falso que fala JSON-RPC por linha.
- **Config**: aditiva (`executor.kind`, default `codex`); workflows atuais válidos.
- **Upstream sync**: conflito potencial restrito ao `agent_runner.ex` (3 linhas) e
  ao schema (bloco novo); ambos triviais de resolver.
- **Acoplamento a Cline**: nenhum — o módulo ACP é genérico; Cline é apenas o
  comando configurado.
- **Outro executor ACP depois**: exige novo módulo/`kind`, sem tocar no ciclo de
  turnos.

### Opção B — adapter ACP escondido atrás da interface atual do Codex

Fazer o cliente atual (`Codex.AppServer`, ou um módulo com esse nome) despachar
internamente para ACP.

- **Diff**: grande; reescreve arquivo upstream (`codex/app_server.ex`, 1071
  linhas) — exatamente o que a política de diff mínimo proíbe.
- **Risco de regressão**: alto; o caminho Codex passa a conviver com código ACP no
  mesmo módulo.
- **Compatibilidade Codex**: preservável apenas com trabalho extra.
- **Upstream sync**: conflito permanente no arquivo mais volátil do caminho de
  execução.
- **Semântica**: o modelo ACP (prompt como request longa, permissão por chamada,
  elicitation, sessão sem turn id) teria de ser espremido em eventos com forma de
  Codex, escondendo justamente o que precisa ser explícito.
- **Veredito**: descartada.

### Opção C — novo `AgentRunner` paralelo para ACP

Duplicar o runner/turnos para ACP e escolher no orquestrador.

- **Diff**: alto e crescente; duplica política (`max_turns`, continuação, hooks,
  worker host, refresh de estado do issue).
- **Risco**: dois donos da mesma política, com drift garantido; o orquestrador
  precisaria de um ramo novo no `spawn`.
- **Testes**: dobra a superfície.
- **Veredito**: descartada.


### Opção D — alternativas encontradas no próprio código

| Variante | Descrição | Avaliação |
|---|---|---|
| **D1**: indireção por módulo selecionado (padrão `Tracker`) | Espelhar `Tracker.@adapters`/`adapter_for_kind/1`: mapa `kind -> módulo` e chamadas diretas, sem `@callback` formal (`lib/symphony_elixir/tracker.ex` linhas 13–27, 93–104) | É o precedente real do repositório; menor diff que A (nenhum contrato formal), mas sem checagem de forma. A diferença para A é só a existência do behaviour — recomenda-se A (behaviour + seleção), porque o custo do `@callback` é pequeno e o ganho é `@impl`/dialyzer |
| **D2**: processo por sessão (`GenServer`/`DynamicSupervisor` do executor) | Introduzir um processo dedicado por sessão para encapsular o cliente ACP | Rejeitada: adiciona supervisão, ciclo de vida e pontos de falha novos sem necessidade — a sessão já vive dentro da Task do worker, que é o dono natural do `try/after` |
| **D3**: shim externo traduzindo ACP ↔ Codex app-server (comando configurado = shim) | Zero diff no Elixir: o Symphony continuaria falando Codex e um binário intermediário falaria ACP | Descartada **apesar de ser a de menor diff**: exigiria reimplementar o protocolo Codex app-server (incluindo approvals, dynamic tools e `thread/tokenUsage/updated`) fora do repositório, criando uma segunda superfície de protocolo sem testes no fork; esconderia o mapeamento ACP justamente do lugar onde ele precisa ser visível e auditável; e não permitiria usar recursos sem forma Codex (`session/request_permission` com opções, `session/cancel` de protocolo). Também conflita com o objetivo declarado do fork (abstração de executor **no** Symphony) |

### Decisão

**Opção A**, na forma de D1 (seguir o padrão de adapter já existente no
repositório). Detalhamento, consequências e implementação planejada em
[ADR-0001](adr/0001-executor-abstraction.md).

## 7. Configuração: evolução decidida (Q1)

Restrições: manter workflows atuais válidos; preservar o default upstream;
permitir selecionar executor; permitir ACP sem obrigar Cline; permitir comando
externo; continuar compatível com reload do `WORKFLOW.md`; não misturar
configuração de modelo (DeepSeek) na arquitetura do Symphony; não colocar segredo
em YAML versionado.

Decisão humana (Q1), que a fase 3 implementa:

- **`executor.kind`** seleciona o executor, com default **`codex`**;
- **`codex.*` é preservado sem breaking change** — nada é renomeado, movido ou
  removido;
- **`acp.*`** existe apenas para configuração **específica** do executor ACP
  (espelhando o estilo do bloco `codex.*`);
- timeouts genéricos **não** migram agora para `executor.*`;
- reuso temporário, pelo caminho ACP, de algum valor que hoje vive em `codex.*`
  é permitido **somente** se registrado explicitamente como **dívida de
  compatibilidade/nomeação** (não como desenho ideal permanente).

Forma conceitual (nomes exatos e shape do schema são confirmados no PR da fase 3;
**nada disto existe no código hoje**):

```yaml
executor:
  kind: codex            # default; "codex" | "acp"
codex:                   # bloco existente, SEM renomear, mover ou remover
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: false
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
acp:                     # só relevante quando executor.kind: acp
  command: <comando do cliente ACP>      # comando externo; sem default no fork
  auto_approve_requests: false           # Q2: fail closed
```

Regras da decisão:

1. `executor` ausente ⇒ comportamento **idêntico** ao atual (`kind: codex`,
   preflight e defaults preservados). Workflows upstream existentes continuam
   válidos, byte a byte, sem edição.
2. `codex.command` continua sendo o comando do executor Codex; o comando do
   executor ACP vive em `acp.*` (config específica daquele executor), não em uma
   chave genérica nova.
3. `acp.*` só é lido quando `kind: acp`; `auto_approve_requests` default
   **`false`** (Q2 — fail closed; nenhuma aprovação automática na fase 3).
4. Modelo (DeepSeek), credenciais e data-dir do agente **não** entram no
   `WORKFLOW.md`: pertencem ao runtime do executor (`~/automation/tools/cline`,
   `~/automation/state/cline`, `~/.config/agentic-dev-environment/env`). O
   Symphony só passa o comando e o env já saneado.
5. Segredo **nunca** literal no YAML: apenas `$VAR` (mecanismo já existente em
   `Config.Schema.resolve_secret_setting/2`) e referências de env.
6. Se a fase 3 reutilizar `codex.turn_timeout_ms`/`read_timeout_ms`/
   `stall_timeout_ms` no caminho ACP (evitando duas fontes do mesmo número), isso
   é **dívida de compatibilidade/nomeação** registrada em
   [ADR-0001](adr/0001-executor-abstraction.md) §Dívidas — não é o desenho ideal e
   deve ser resolvido em mudança própria, com aliases de compatibilidade, quando
   houver mais de um executor em uso real.

## 8. Segurança e isolamento no caminho ACP

Esta seção separa o que o Symphony **consegue** impor do que depende do executor
ou do projeto consumidor. Ela existe para impedir promessa falsa de sandbox.

### 8.1 O que o Symphony impõe no caminho ACP

| Controle | Como |
|---|---|
| Local do workspace | `Workspace.create_for_issue/2` + `validate_workspace_cwd/2` antes de qualquer launch (canonicalização, prefixo do root, rejeição do root e de escape por symlink) |
| `cwd` do agente | `session/new.cwd` recebe o workspace canônico; o protocolo exige caminho absoluto e o Symphony só envia caminho validado |
| Raiz efetiva | **não** anunciar `additionalDirectories` ⇒ sem root extra |
| Segredos no filho | o env do subprocesso é montado removendo `secret_environment_names` (mesmo código do caminho Codex); nenhuma credencial do tracker é passada |
| Escrita fora do workspace | o Symphony não escreve fora do workspace da issue; o agente é o único que escreve dentro dele |
| Encerramento e retry | o Symphony mata o subprocesso e agenda retry; nenhuma recuperação automática de "estado sujo" fora do workspace |
| Privilégio | nenhum: o pipeline roda como usuário comum, sem sudo, sem socket do Docker, sem credencial privilegiada (perfis `privileged` são fase 10 da plataforma) |
| Observabilidade | eventos e logs com `session_id`; dashboard mostra último evento por issue |

### 8.2 O que depende do executor ACP (e o Symphony **não** garante)

- **Fronteira de escrita/leitura**: se o agente respeita o `cwd` como raiz é
  comportamento do agente; ACP não define nem fiscaliza. O Symphony não tem como
  verificar depois (não recebe o conteúdo dos arquivos).
- **Rede**: não há `networkAccess` no ACP. Nada impede o processo do agente de
  acessar a rede; o Symphony não intermedeia.
- **Execução de comandos**: o agente executa comandos com suas próprias
  ferramentas; o Symphony só veria isso se tivesse anunciado `terminal` (não
  anuncia).
- **Permissões**: com `acp.auto_approve_requests: false` (default) o Symphony não
  aprova nada automaticamente, mas a decisão de pedir permissão é do agente — um
  agente que não pede não é bloqueado por isso.
- **Credenciais do modelo**: vivem na configuração do próprio agente (ex.:
  data-dir do Cline em `~/automation/state/cline`); o Symphony não as lê, não as
  copia e não as loga.

### 8.3 O que depende do projeto consumidor/plataforma

- colocar os segredos no lugar certo (`~/.config/agentic-dev-environment/env`,
  `600`) e nunca em YAML versionado;
- fornecer `hooks.after_create`/`before_run` que clonem/preparem o projeto
  dentro do workspace (o Symphony não cria o clone "certo" sozinho);
- definir gates determinísticos e aceitar apenas Draft PR como saída (ADR-0006 da
  plataforma);
- decidir, por projeto, se aceita um executor sem sandbox formal.

### 8.4 Gaps de enforcement (declaração explícita)

1. Não existe no ACP equivalente a `thread_sandbox`/`turn_sandbox_policy`;
   portanto **não há sandbox de plataforma** no caminho ACP.
2. Não há como o Symphony limitar recursos (CPU/RAM/tempo total) do processo do
   agente: só o timeout de silêncio do turno e o kill pelo orquestrador.
3. Não há verificação de que o agente escreveu apenas dentro do workspace.
4. `:stderr_to_stdout` no launch mistura log do agente com o protocolo; a defesa
   é o parser tolerante (D22), não uma garantia de framing.

Se o projeto exigir garantias de sandbox equivalentes às do Codex, a mitigação
tem de vir de fora do ACP (ex.: isolamento do processo por SO, container, ou
aceitar apenas o executor Codex para essa issue). Isso é decisão de plataforma,
não deste fork.


## 9. O que fica fora desta fase

Explícito, para evitar que a análise seja lida como plano de implementação:

- alterar `agent_runner.ex`, `codex/app_server.ex` ou qualquer arquivo upstream;
- criar adapter ACP funcional, fake executor funcional ou agente ACP de teste;
- adicionar dependência (Elixir ou externa) para ACP;
- alterar o schema executável (`config/schema.ex`) ou o `WORKFLOW.md` do fork;
- conectar Cline, DeepSeek ou qualquer modelo;
- implementar MCP local, cancelamento gracioso, `session/load`,
  modos/config options, elicitation ou `session/close` (fases ≥ 4);
- alterar o prompt de continuação hardcoded (Q9 — muda na fase 3, junto com a
  abstração);
- corrigir o flake de timing do gate (`core_test.exs:1062`), que tem issue
  própria ([#2](https://github.com/rbcorrea26/symphony-acp/issues/2)) e PR
  separado;
- abrir PR de implementação ou iniciar `feat/acp-agent-runner`.

## 10. Decisões humanas registradas (Q1–Q10)

Decididas em **2026-09-27** e incorporadas aos ADRs. A coluna "Registrado em"
aponta onde a decisão é normativa.

| # | Decisão | Registrado em |
|---|---|---|
| Q1 | Configuração: `executor.kind` com default `codex`; `codex.*` preservado sem breaking change; `acp.*` apenas para configuração específica do ACP; timeouts genéricos **não** migram agora para `executor.*`; reuso temporário de valor de `codex.*` pelo ACP só como dívida explícita de compatibilidade/nomeação | §7 acima e [ADR-0001](adr/0001-executor-abstraction.md) §Decisões humanas incorporadas / §Dívidas |
| Q2 | `session/request_permission`: default **`false`** (fail closed); nada de autoaprovação; autoaprovação futura é configuração explícita e testada; **não** assumir equivalência semântica com `approval_policy: never` do Codex | [ADR-0002](adr/0002-acp-protocol-mapping.md) §2.5 |
| Q3 | Capabilities do cliente: anunciar o mínimo necessário; **sem `fs`**; **sem `terminal`**; capacidade não anunciada é *unsupported*; ampliar só em fase posterior, com necessidade e teste concretos | [ADR-0002](adr/0002-acp-protocol-mapping.md) §2.2 |
| Q4 | Ferramentas do tracker: **indisponíveis** no primeiro executor ACP (fake); **não** implementar MCP local nesta fase; MCP pode ser analisado depois como caminho para client-side/dynamic tools | [ADR-0002](adr/0002-acp-protocol-mapping.md) §2.7 |
| Q5 | `auth_required`: execução **bloqueia com erro explícito** e exige ação humana (handoff); autenticação continua manual; **não** automatizar credenciais; **nenhum segredo** no Symphony | [ADR-0002](adr/0002-acp-protocol-mapping.md) §2.2 e §2.8 |
| Q6 | Token accounting: ausência de dado ACP **não** vira zero "real"; representar como **indisponível/ausente**; **nunca** fabricar métricas; se o dashboard atual não suportar ausência sem ambiguidade, é dívida a resolver **antes da integração real do Cline** | [ADR-0002](adr/0002-acp-protocol-mapping.md) §2.8 |
| Q7 | Cancelamento: a fase 3 mantém cancelamento/encerramento simples compatível com o lifecycle atual da Task/processo; cancelamento gracioso ACP fica para a fase de integração real; limitação explícita; **não** afirmar que `Port.close` equivale a `session/cancel` | [ADR-0002](adr/0002-acp-protocol-mapping.md) §2.3 e §2.6 |
| Q8 | Nomes `codex_*`: manter inicialmente (diff mínimo) e registrar dívida de naming/telemetria; **não** refatorar nomes agora | [ADR-0001](adr/0001-executor-abstraction.md) §Dívidas e [ADR-0002](adr/0002-acp-protocol-mapping.md) §2.4 |
| Q9 | Prompt de continuação: texto hardcoded que menciona "Codex" deve ser **neutralizado quando a abstração entrar** (fase 3); **não** alterar o prompt nesta PR documental | [ADR-0001](adr/0001-executor-abstraction.md) §Decisões humanas incorporadas |
| Q10 | Executor inicial: fase 3 usa **executor ACP fake determinístico**; Cline real só na fase 4; DeepSeek só depois da integração do Cline; coerente com o roadmap da plataforma | [ADR-0001](adr/0001-executor-abstraction.md) §Implementação |

Consequência: **não há decisão humana aberta que bloqueie a fase 3.** O que resta
são dívidas registradas (item acima, Q1/Q6/Q8) e capacidades deliberadamente
adiadas para fases ≥ 4 (MCP local, cancelamento gracioso, `session/load`,
elicitation interativo, modos/config options, protocolo ACP v2). O próximo passo
concreto é o **fake ACP determinístico**, partindo da `main` integrada com estes
ADRs.

## 11. Referências

- `SPEC.md` §4.1.5–4.1.7 (workspace/attempt/sessão), §4.2 (identificadores e
  composição do `session_id`), §5.3.6 (`codex`), §6.1–6.4 (configuração,
  reload, preflight), §10.1–10.7 (agent runner protocol).
- `elixir/WORKFLOW.md` (front matter de exemplo), `elixir/README.md`
  (contrato das chaves `codex.*`), `elixir/AGENTS.md` (convenções e gates),
  `elixir/docs/logging.md`, `elixir/docs/token_accounting.md`.
- Código: `lib/symphony_elixir/agent_runner.ex`, `lib/symphony_elixir/codex/app_server.ex`,
  `lib/symphony_elixir/codex/dynamic_tool.ex`, `lib/symphony_elixir/config/schema.ex`,
  `lib/symphony_elixir/config.ex`, `lib/symphony_elixir/workspace.ex`,
  `lib/symphony_elixir/orchestrator.ex`, `lib/symphony_elixir/tracker.ex`.
- Testes: `test/symphony_elixir/app_server_test.exs`,
  `test/symphony_elixir/workspace_and_config_test.exs`,
  `test/symphony_elixir/orchestrator_status_test.exs`,
  `test/support/test_support.exs`.
- ACP oficial: `https://agentclientprotocol.com` (seções citadas em §3) e
  `https://github.com/agentclientprotocol/agent-client-protocol`
  (release de schema `schema-v1.23.0`, 2026-09-18).
- Plataforma (decisões já aceitas, não duplicadas aqui):
  `rbcorrea26/agentic-dev-environment` → `docs/architecture/adr/0001..0006`,
  `docs/architecture/pipeline.md`, `docs/security/permissions.md`.
- Flake de gate conhecido (pré-existente, não causado por documentação):
  `core_test.exs:1062` falha ocasionalmente por timing e tem issue própria —
  [issue #2](https://github.com/rbcorrea26/symphony-acp/issues/2). Evidência de
  execução (verde/vermelho, tempos) é transitória e vive no CI/PR, não aqui.
