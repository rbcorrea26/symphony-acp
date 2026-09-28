# ADR-0002 — mapeamento do protocolo ACP no Symphony

- **Status:** proposto
- **Data:** 2026-09-27
- **Decisores:** arquitetura do fork (rbcorrea26)
- **Relacionado a:** [0001-executor-abstraction.md](0001-executor-abstraction.md),
  [../acp-analysis.md](../acp-analysis.md) (matriz `D1`–`D33`),
  `SPEC.md` §4.2 e §10, e (plataforma)
  `agentic-dev-environment/docs/architecture/adr/0003-cline-deepseek-como-executor-inicial.md`

## Contexto

O [ADR-0001](0001-executor-abstraction.md) decide a forma da abstração
(`SymphonyElixir.Executor` com uma implementação por protocolo) e preserva o
caminho Codex. Este ADR decide **como** a implementação ACP traduz o protocolo
para o modelo que o Symphony já tem, e o que **não** será traduzido.

Estado atual relevante (verificado em `codex/app_server.ex` e `orchestrator.ex`):
o Symphony fala JSON-RPC 2.0 delimitado por linha sobre stdio; abre uma thread e
turnos (`thread/start`, `turn/start`), consome `turn/*`/`item/*`/notificações,
auto-avalia aprovações segundo `codex.approval_policy` (ou reporta
`:approval_required` e bloqueia a issue), executa ferramentas dinâmicas no host,
mede stall por timestamp de evento e extrai tokens de campos específicos de
Codex. O `session_id` é composto como `<thread_id>-<turn_id>` (`SPEC.md` §4.2) e
é usado em logs, dashboard, `turn_count` e accounting.

### Especificação ACP de referência (fonte oficial)

| Item | Valor |
|---|---|
| Documentação oficial | `https://agentclientprotocol.com` — seções `Protocol v1`: Overview, Initialization, Session Setup, Prompt Turn, Tool Calls, Cancellation, Terminals, File System, Elicitation, Session Modes, Transports, Schema |
| Repositório oficial | `https://github.com/agentclientprotocol/agent-client-protocol` (Apache-2.0) |
| Data da consulta | 2026-09-27 |
| Versão de protocolo | **1** (inteiro MAJOR negociado em `initialize.protocolVersion`); v2 está em *draft* (pré-releases `schema-v2.0.0-alpha.*`) e **não** é alvo |
| Release de schema v1 mais recente na consulta | `schema-v1.23.0` (tag commit `6d08f41`, publicada em 2026-09-18T10:43:47Z; assets `meta.json`, `meta.unstable.json`, `schema.json`, `schema.unstable.json`) |
| O que a implementação deve fixar | a release exata do `schema.json` v1 usada, registrada no PR da fase 3 (a spec continua sendo a autoridade; este ADR só resume o necessário para justificar o mapeamento) |

Papéis: no ACP, o **client** é quem lança e controla o processo; o **agent** é o
programa que modifica código. No Symphony, o **Symphony é o client** e o executor
(Cline, por exemplo) é o **agent** — o inverso da leitura intuitiva de "Symphony
como cliente do Codex".

## Decisão

O mapeamento abaixo é normativo para a implementação da fase 3. Ele **não
inventa** comportamento: onde a spec não define, está registrado como gap e a
decisão é "não fazer".

### 2.1 Lançamento do processo e transporte (`D1`, `D16`)

- Reutilizar o mesmo mecanismo do caminho Codex: `Port.open` de `bash -lc
  <executor.command>` com `cd` no workspace validado, `:stderr_to_stdout`, `line:
  1_048_576` e env saneado (remoção de `secret_environment_names`); remoto via
  `SSH.start_port`.
- Transporte `stdio` do ACP: JSON-RPC delimitado por `\n`. O parser **permanece
  tolerante** a linhas não-JSON (a spec proíbe o agente de escrever não-ACP em
  `stdout`, mas `:stderr_to_stdout` mistura o log do agente no mesmo canal).
- O comando é configuração (`executor.command`); nada de modelo/credencial no
  YAML.

### 2.2 Handshake e capacidades (`D2`, `D3`, `D4`)

- Enviar `initialize` com `protocolVersion: 1`, `clientInfo` (Symphony +
  versão) e `clientCapabilities` **mínimos** (default: nenhuma capacidade de
  cliente anunciada — Q3).
- Validar a resposta: se o `protocolVersion` devolvido não for suportado, falhar
  a sessão (`{:error, {:acp_version_unsupported, version}}`) sem tentar
  compatibilidade implícita.
- Guardar `agentCapabilities`/`agentInfo`/`authMethods` na sessão para decidir
  depois o que é permitido chamar; **nunca** chamar método cuja capacidade o
  agente não anunciou.
- Não existe notificação `initialized` no ACP (diferente do Codex): enviar apenas
  `initialize`.
- `auth_required`: **não** automatizar autenticação (a plataforma exige `cline
  auth` manual — ADR-0003). Tratar como erro/bloqueio registrado; nunca abrir
  prompt interativo.

### 2.3 Sessão e turno (`D5`, `D6`, `D7`, `D25`, `D26`)

- `start_session/2` → valida o workspace (mesma canonicalização do caminho
  Codex) e chama `session/new` com `cwd` absoluto e `mcpServers: []`. **Não**
  anunciar `additionalDirectories`.
- `sessionId` é guardado como identidade de sessão ACP; **não** existe turn id no
  protocolo.
- `run_turn/4` → `session/prompt` com `prompt: [%{"type" => "text", "text" =>
  prompt}]`. Essa request fica **pendente** durante todo o turno: o loop do
  turno continua consumindo `session/update` e só termina quando a resposta chega
  (ou quando estoura timeout/saída do processo).
- **Identidade de sessão emitida ao orquestrador**: `session_id =
  "<sessionId>-<n>"`, com `n` = número local do turno dentro da sessão
  (1-based). Emitir `:session_started` a cada turno com esse `session_id`, o que
  preserva `turn_count` e o dashboard (`orchestrator.ex` 1552–1568). A composição
  `<thread>-<turn>` do `SPEC.md` §4.2 permanece para o Codex; para ACP o slot do
  turno recebe o contador local — extensão documentada, não conflito.
- `stopReason` da resposta de `session/prompt`:
  - `end_turn` ⇒ `{:ok, %{session_id: ..., turn_id: n, result: ...}}`
  - `cancelled` ⇒ `{:error, {:turn_cancelled, %{...}}}`
  - `max_tokens`, `max_turn_requests`, `refusal` ⇒
    `{:error, {:turn_failed, %{stop_reason: reason}}}`
- Turnos de continuação reutilizam a mesma `sessionId` (paridade com reuso de
  `thread_id`), limitados por `agent.max_turns`; a política continua no
  `AgentRunner`, não no executor.
- `stop_session/1` fecha o port (paridade com `Port.close`). `session/close` e
  `session/load` ficam fora da fase 3.

### 2.4 Streaming e eventos (`D8`, `D9`, `D10`, `D22`, `D29`)

- Cada `session/update` é traduzido para uma mensagem no formato que o
  orquestrador já consome (`%{event: atom, timestamp: DateTime, payload: ...,
  raw: ...}`, eventualmente com `session_id`/`codex_app_server_pid`), enviada por
  `on_message`.
- Mapeamento de variantes (fase 3):
  - `agent_message_chunk`, `agent_thought_chunk`, `user_message_chunk`,
    `tool_call`, `tool_call_update`, `plan`, `available_commands_update`,
    `current_mode_update`, `config_option_update`, `session_info_update`,
    `usage_update` ⇒ evento `:notification` com o payload ACP íntegro (o
    dashboard humaniza; nenhum deles altera decisão de orquestração);
  - request `session/request_permission` ⇒ ver §2.5;
  - resposta final de `session/prompt` ⇒ `:turn_completed` (ou erro, §2.3);
  - linha não-JSON ⇒ log (`:debug`/`:warning` por conteúdo) e evento
    `:malformed` quando parecer frame JSON, como hoje.
- `payload` e `raw` sempre presentes no evento (diagnóstico e
  `StatusDashboard.humanize_codex_message/1`).
- O pid do processo filho é exposto no mesmo campo já existente
  (`codex_app_server_pid`), obtido do port — o ACP não fornece pid no protocolo.


### 2.5 Aprovação e entrada do usuário (`D13`, `D14`)

- **Permissão** (`session/request_permission`): a spec obriga o cliente a
  responder. Com `executor.acp.auto_approve_requests: true`, escolher a opção de
  menor escopo entre as `allow_*` oferecidas (preferência:
  `allow_once` > `allow_always`; se nenhuma existir, responder `cancelled`) e
  emitir `:approval_auto_approved` com `decision` legível.
- Com `auto_approve_requests: false` (default fail-safe), manter a semântica
  atual: emitir `:approval_required` e terminar o turno com
  `{:error, {:approval_required, payload}}` — o orquestrador bloqueia a issue e
  o processo da sessão é encerrado (mesmo desfecho do caminho Codex quando
  `approval_policy != "never"`). O comportamento de **não** deixar request pendente
  é obrigatório: o cliente responde `cancelled`/`reject_once` antes de falhar,
  para não deixar o agente esperando indefinidamente.
- **Entrada do usuário / elicitation**: fase 3 **não** anuncia
  `elicitation.form`/`elicitation.url`. Consequência: o agente não pode pedir
  input estruturado (e não pode pedir um modo não anunciado). Se o agente
  terminar o turno por falta de informação, o resultado é uma conclusão/erro
  normal, tratada pelo `continue_with_issue?`/retry existentes. Não há
  substituição para a heurística de auto-resposta de
  `item/tool/requestUserInput`; ela é específica do Codex.
- Decisão de produto registrada: "run não supervisionado que precisa de humano"
  deve terminar com bloqueio/erro visível, nunca com espera indefinida.

### 2.6 Cancelamento, timeout e stall (`D18`, `D19`, `D20`, `D21`)

- **Cancelamento**: fase 3 mantém o modelo atual — o orquestrador interrompe a
  Task do worker, o `after` fecha o port e o subprocesso morre. `session/cancel`
  e `$/cancel_request` **não** são enviados (não existe canal do orquestrador
  para o loop do runner). Gap registrado; cancelamento gracioso exige mudança de
  arquitetura (ADR próprio, fase ≥ 4).
- **Timeout**: `codex.read_timeout_ms` aplica-se às requests de resposta rápida
  (`initialize`, `session/new`); `codex.turn_timeout_ms` aplica-se ao silêncio
  máximo entre mensagens recebidas enquanto o `session/prompt` está pendente
  (cada mensagem reinicia). `session/prompt` **nunca** usa timeout de resposta.
- **Stall**: mecanismo inalterado (`codex.stall_timeout_ms` sobre o timestamp do
  último evento, no orquestrador). Nota de risco: um agente ACP silencioso é
  indistinguível de travado até o timeout; `agent_thought_chunk` funciona como
  heartbeat natural quando o agente emite.
- **Crash**: `{:exit_status, status}` ⇒ `{:error, {:port_exit, status}}`,
  idêntico ao Codex, deixando o retry com backoff por conta do orquestrador.

### 2.7 Ferramentas e sandbox (`D10`, `D11`, `D12`, `D15`, `D32`)

- Ferramentas do agente (`tool_call`/`tool_call_update`) são **observadas** e
  reportadas como evento; o Symphony não as executa nem as bloqueia.
- **Não** haverá, na fase 3, registro de ferramenta do cliente: ACP não tem
  equivalente a `dynamicTools`, e as capacidades de cliente
  (`fs.readTextFile`/`fs.writeTextFile`, `terminal`) **não** serão anunciadas. O
  resultado prático é que as ferramentas do tracker (`linear_graphql`,
  `github_api`, …) ficam indisponíveis no caminho ACP — gap explícito, com
  caminho futuro possível via MCP local em `session/new.mcpServers` (fase ≥ 4,
  novo ADR).
- **Sandbox**: o ACP não define política de sandbox/filesystem/rede. Portanto:
  1. o Symphony **não** oferece no caminho ACP o que oferece via
     `codex.thread_sandbox`/`turn_sandbox_policy`;
  2. `codex.approval_policy`, `thread_sandbox` e `turn_sandbox_policy` são
     lidos/validados como hoje, mas **não** são passados ao agente ACP (não
     existe campo);
  3. a documentação de configuração deve dizer isso explicitamente, sem
     prometer isolamento;
  4. mitigações efetivas são do projeto/plataforma (workspace dedicado, sem
     segredos no env do filho, sem privilégio, Draft PR, gates).

### 2.8 Erros e limites conhecidos

- Taxonomia de erro exposta: `:response_timeout`, `:turn_timeout`,
  `:port_exit`, `:turn_failed`, `:turn_cancelled`, `:approval_required`,
  `:turn_input_required`, mais os novos específicos de ACP:
  `{:acp_version_unsupported, version}`, `{:acp_response_error, error}` e
  `{:acp_auth_required, methods}`.
- Limites declarados: sem sandbox (D15), sem ferramentas do cliente
  (D11/D12), sem elicitation (D14), tokens possivelmente zerados (D27), sem
  rate limits (D28), sem cancelamento gracioso (D18), sem `session/load`
  (sessão nova a cada tentativa).


### 2.9 O que permanece específico de Codex (não é abstraído)

| Item | Onde fica |
|---|---|
| `approval_policy` com valores/mapa `reject`, e a decisão `acceptForSession`/`approved_for_session` | `Codex.AppServer` |
| `thread_sandbox` / `turn_sandbox_policy` (incluindo `workspaceWrite`, `writableRoots`, `networkAccess`) | `Codex.AppServer` + `Config.Schema.resolve_*_turn_sandbox_policy/3` |
| `dynamicTools` e `item/tool/call` executado no host (`DynamicTool`) | `Codex.AppServer` + `SymphonyElixir.Codex.DynamicTool` |
| `thread/tokenUsage/updated`, `total_token_usage`/`last_token_usage`, usage em `turn/completed` | extração no `Orchestrator` (caminhos específicos) |
| Métodos `item/*`, `execCommandApproval`, `applyPatchApproval`, `mcpServer/elicitation/request` e a heurística `mcp_tool_call_approval_*` | `Codex.AppServer` |
| `turn/start` devolvendo `turn.id` imediatamente + `turn/completed` como notificação | `Codex.AppServer` |
| Notificação `initialized` e `capabilities.experimentalApi` | `Codex.AppServer` |

### 2.10 O que permanece específico de ACP (não é usado na fase 3)

| Item | Motivo |
|---|---|
| `session/request_permission` com `options[].kind` e `outcome` | usado apenas no modo auto-aprovar; sem modo interativo |
| `elicitation/create` (form/url), `elicitation/complete` | não anunciado (Q3); sem canal humano no run |
| `session/load`, `session/resume`, `session/close`, `session/delete`, `session/list` | fora de escopo; cada tentativa abre sessão nova |
| `session/set_mode`, `modes`, `session/set_config_option`, `config_option_update` | perfis `read`/`dev`/`privileged` são conceito da plataforma, não do protocolo; mapear é decisão futura |
| `terminal/*`, `fs/*` | capacidades de cliente que ampliariam privilégio; não anunciadas |
| `mcpServers` | caminho possível para ferramentas do tracker (fase ≥ 4) |
| `$/cancel_request`, `session/cancel` | sem canal de cancelamento no runner atual |
| `usage_update` (custo/contexto) | mapeamento fino pendente (D27) |
| `authMethods`/`authenticate`/`logout` | autenticação do agente é manual e fora do Symphony |
| `_meta` (extensibilidade) | sem uso planejado |
| protocolVersion 2 (draft) | fora de escopo até estabilizar |

### 2.11 O que o Symphony abstrai

O behaviour do [ADR-0001](0001-executor-abstraction.md) abstrai exatamente:
abrir sessão, executar um turno com prompt e stream de eventos, e encerrar a
sessão. Permanecem Symphony-specific (e únicos donos) a decisão de dispatch,
concorrência, workspace, hooks, prompt/template, continuação por estado do issue,
retry/backoff, stall, bloqueio por input-required, cleanup terminal e
observabilidade. Nenhuma regra de negócio de projeto consumidor entra no
executor; nenhum detalhe de protocolo vaza para o `AgentRunner` além do
`session_id` de log.


## Consequências

- **Positivas:** o comportamento observável do Symphony é preservado (mesmos
  eventos, mesmos campos, mesma política de retry/stall/bloqueio); o caminho Codex
  não muda; a fase 3 é validável com um agente ACP falso, sem Cline, sem modelo e
  sem credencial; os gaps ficam declarados em vez de escondidos atrás de uma
  tradução otimista.
- **Negativas / custos:** no caminho ACP o Symphony tem menos controle e menos
  observabilidade do que no Codex (sem sandbox, sem tokens confiáveis, sem
  ferramentas do cliente, sem cancelamento gracioso); o executor ACP recebe menos
  contexto institucional (sem `title`, sem ferramentas do tracker, sem
  elicitation); a dívida de nomes `codex_*` permanece; a implementação precisa
  manter um segundo protocolo sob teste.
- **Obrigações:** implementar somente o que está nesta decisão; toda extensão
  (MCP local, cancelamento, `session/load`, elicitation, modos) exige ADR novo;
  registrar no PR a release exata do schema ACP usada; cobrir o caminho ACP com
  agente falso antes de qualquer executor real; atualizar
  [../acp-analysis.md](../acp-analysis.md) se a spec mudar de forma material
  (versão nova do schema v1 ou estabilização do v2); registrar divergências de
  arquivo upstream em [../divergences.md](../divergences.md).

## Alternativas descartadas

| Alternativa | Por que foi descartada |
|---|---|
| Traduzir `codex.approval_policy` para uma política global de permissão ACP | não existe política global no ACP; a decisão é por chamada, e inventar um mapeamento daria falsa sensação de controle |
| Anunciar `fs`/`terminal` para compensar a ausência de `dynamicTools` | troca um gap por uma ampliação de privilégio (o agente passaria a executar arquivos/comandos no processo do Symphony), sem ganho de isolamento |
| Anunciar `elicitation.form` e responder automaticamente | a resposta estruturada exigiria decisão humana; auto-responder seria pior que não anunciar (o agente agiria com informação fabricada) |
| Auto-aprovar permissões por padrão (paridade com `approval_policy: never` do `WORKFLOW.md` de exemplo) | aprovado não é padrão seguro para um executor sem sandbox; fica como configuração explícita (Q2) |
| Recusar a resposta ao `session/request_permission` e seguir esperando operador | a spec exige resposta do cliente; deixar pendente trava o agente e o stall só cortaria depois |
| Implementar `session/load` para "continuar" a sessão após retry | o ACP só oferece `loadSession` se o agente suportar, e o Symphony hoje **não** tenta retomar thread em retry (abre nova); uniformizar exigiria mudança de comportamento upstream |
| Assumir que tokens virão em formato Codex (`tokenUsage.total`) | inventaria contadores; o correto é degradar para zero e registrar o gap (D27) |
| Copiar a especificação ACP para dentro do repositório | a spec é externa e versionada por ela mesma; duplicar cria fonte divergente |

## Implementação

Estado: **pendente** (nada implementado). Este ADR descreve o mapeamento a ser
implementado em `SymphonyElixir.Executor.Acp`, validado por um agente ACP falso,
depois das decisões humanas de Q1–Q3
([../acp-analysis.md](../acp-analysis.md) §10) e do merge deste ADR.

Sequência prevista para a fase 3 (plataforma: "runner ACP com fake"):

1. responder Q1–Q3 e registrar a resposta (aqui, em emenda, ou em ADR novo);
2. criar a abstração e a delegação Codex (ADR-0001) com testes de paridade;
3. implementar o cliente ACP conforme §2.1–§2.8, com `@spec` em todo `def`
   público (`mix specs.check`);
4. escrever o agente ACP falso (script executável que fala JSON-RPC por linha) e
   os testes de: handshake/negociação de versão, `session/new`, turno completo,
   silêncio, morte do processo, frame malformado, permissão (auto e não auto),
   `stopReason: cancelled` e `stopReason` de falha;
5. registrar divergências, atualizar `elixir/README.md`/`WORKFLOW.md` no que
   mudou e rodar `make -C elixir all`.

Fora do escopo explícito (fases ≥ 4, cada um exigindo decisão própria): MCP local
para ferramentas do tracker, cancelamento gracioso, `session/load`,
elicitation/`requestUserInput` interativo, modos/config options, mapeamento fino
de `usage_update`, aprovação humana fora de banda e protocolo ACP v2.
