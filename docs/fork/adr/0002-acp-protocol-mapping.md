# ADR-0002 — mapeamento do protocolo ACP no Symphony

- **Status:** aceito (implementação pendente)
- **Data:** 2026-09-27 — decisões humanas Q2, Q4, Q5, Q6 e Q7 incorporadas nesta revisão
- **Decisores:** arquitetura do fork (rbcorrea26)
- **Relacionado a:** [0001-executor-abstraction.md](0001-executor-abstraction.md),
  [../acp-analysis.md](../acp-analysis.md) (matriz `D1`–`D33` e decisões Q1–Q10),
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

- Reutilizar o mesmo mecanismo do caminho Codex: `Port.open` de `bash -lc` com o
  comando do executor configurado, `cd` no workspace validado,
  `:stderr_to_stdout`, `line: 1_048_576` e env saneado (remoção de
  `secret_environment_names`); remoto via `SSH.start_port`.
- Transporte `stdio` do ACP: JSON-RPC delimitado por `\n`. O parser **permanece
  tolerante** a linhas não-JSON (a spec proíbe o agente de escrever não-ACP em
  `stdout`, mas `:stderr_to_stdout` mistura o log do agente no mesmo canal).
- O comando é configuração específica do executor ACP (`acp.command`), conforme
  [../acp-analysis.md](../acp-analysis.md) §7 e Q1; nada de modelo/credencial no
  YAML.

### 2.2 Handshake e capacidades (`D2`, `D3`, `D4`, `D5`)

- Enviar `initialize` com `protocolVersion: 1`, `clientInfo` (Symphony + versão) e
  `clientCapabilities` **mínimos**.
- **Decisão Q3 (capabilities):** anunciar apenas o mínimo necessário. Na fase 3
  **não** se anuncia `fs` (nem `readTextFile`, nem `writeTextFile`) e **não** se
  anuncia `terminal`. Capacidade não anunciada é considerada *unsupported* pelo
  agente; ampliar capacidades só em fase posterior, com necessidade e teste
  concretos — nunca "para destravar" um caso pontual.
- Validar a resposta: se o `protocolVersion` devolvido não for suportado, falhar a
  sessão (`{:error, {:acp_version_unsupported, version}}`) sem tentar
  compatibilidade implícita.
- Guardar `agentCapabilities`/`agentInfo`/`authMethods` na sessão para decidir
  depois o que é permitido chamar; **nunca** chamar método cuja capacidade o
  agente não anunciou.
- Não existe notificação `initialized` no ACP (diferente do Codex): enviar apenas
  `initialize`.
- **Decisão Q5 (`auth_required`):** a execução **bloqueia com erro explícito** e
  exige ação humana (handoff). A autenticação do agente continua **manual**
  (ex.: `cline auth`, ADR-0003 da plataforma): nada de autenticar credencial
  automaticamente, nada de abrir prompt interativo e **nenhum segredo é
  armazenado pelo Symphony**. O erro registrado é `{:acp_auth_required, methods}`
  com a lista de métodos anunciada pelo agente.

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
- **Identidade de sessão emitida ao orquestrador (ambíguo por natureza — ler com
  atenção):** `session_id = "<sessionId>-<n>"`, com `n` = contador **local** de
  turno dentro da sessão (1-based). Esse `session_id` é um **identificador
  interno/sintético do Symphony**, criado apenas para preservar `turn_count`,
  dashboard e logs (`orchestrator.ex` 1552–1568). Ele **não** é um turn id
  nativo do ACP (o protocolo não tem esse conceito) e **nunca** deve ser enviado
  de volta ao agente como se fosse identidade ACP oficial: o único identificador
  trocado com o agente é o `sessionId` devolvido por `session/new`. A composição
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
- **Encerramento (`stop_session/1`) — limitação explícita:** o que existe na fase
  3 é o **encerramento do processo/transporte** (`Port.close`, com paridade ao
  caminho Codex). Isso **não** é equivalente semântico de `session/cancel`,
  `session/close` nem de qualquer fechamento gracioso do ACP: o port fecha o
  subprocesso; o protocolo não recebe nenhuma notificação de cancelamento e o
  agente não tem chance de encerrar trabalho de forma ordenada. `session/close` e
  `session/load` ficam fora da fase 3 (ver Q7 em §2.6). A implementação futura
  deve **distinguir lifecycle do processo** (port/subprocesso, hoje) de
  **lifecycle da sessão ACP** (a criar), sem tratar um como o outro.

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
- **Decisão Q8 (nomes):** os nomes internos `codex_*` (estado do orquestrador,
  telemetria, payload do dashboard) são **preservados temporariamente** para
  manter o diff mínimo. É dívida registrada em
  [ADR-0001](0001-executor-abstraction.md) §Dívidas, **não** desenho ideal, e
  **não** se refatora nome nesta fase (nem em docs, nem em código).


### 2.5 Aprovação e entrada do usuário (`D13`, `D14`)

- **Decisão Q2 (`session/request_permission`): default `false`, fail closed.** Na
  fase 3 **não** se aprova permissão automaticamente. Ao receber a request, o
  cliente **responde** (a spec obriga) com a opção de menor escopo disponível
  (`reject_once`, ou `cancelled` se não houver opção de recusa), emite
  `:approval_required` e termina o turno com
  `{:error, {:approval_required, payload}}` — o orquestrador bloqueia a issue e o
  processo é encerrado. Nunca deixar a request pendente (o agente ficaria
  esperando indefinidamente).
- Qualquer autoaprovação futura é **configuração explícita** e precisa de teste
  próprio; e **não** se assume equivalência semântica entre essa chave e o
  `codex.approval_policy: never` do Codex (são mecanismos diferentes: um responde
  permissão por chamada, o outro é política global de sandbox/aprovação do Codex).
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

- **Decisão Q7 (cancelamento): adiado.** A fase 3 mantém o cancelamento e o
  encerramento simples, compatíveis com o lifecycle atual da Task/processo do
  worker: o orquestrador interrompe a Task, o `after` fecha o port e o
  subprocesso morre. `session/cancel` e `$/cancel_request` **não** são enviados
  (não existe canal do orquestrador para o loop do runner) e o cancelamento
  gracioso ACP fica para a **fase de integração real** (≥ 4), com ADR próprio.
- Limitação explícita: **não** se afirma que `Port.close` é equivalente a
  `session/cancel`, a `session/close` ou a qualquer encerramento gracioso do ACP
  (ver §2.3). O que existe é teardown de processo/transporte.
- **Timeout**: `codex.read_timeout_ms` aplica-se às requests de resposta rápida
  (`initialize`, `session/new`); `codex.turn_timeout_ms` aplica-se ao silêncio
  máximo entre mensagens recebidas enquanto o `session/prompt` está pendente
  (cada mensagem reinicia). `session/prompt` **nunca** usa timeout de resposta.
  (Reuso temporário de chaves `codex.*` — dívida registrada em
  [ADR-0001](0001-executor-abstraction.md) §Dívidas, conforme Q1.)
- **Stall**: mecanismo inalterado (`codex.stall_timeout_ms` sobre o timestamp do
  último evento, no orquestrador). Nota de risco: um agente ACP silencioso é
  indistinguível de travado até o timeout; `agent_thought_chunk` funciona como
  heartbeat natural quando o agente emite.
- **Crash**: `{:exit_status, status}` ⇒ `{:error, {:port_exit, status}}`,
  idêntico ao Codex, deixando o retry com backoff por conta do orquestrador.

### 2.7 Ferramentas e sandbox (`D10`, `D11`, `D12`, `D15`, `D32`)

- Ferramentas do agente (`tool_call`/`tool_call_update`) são **observadas** e
  reportadas como evento; o Symphony não as executa nem as bloqueia.
- **Decisão Q4 (ferramentas do tracker): indisponíveis no primeiro executor ACP
  (fake).** ACP não tem equivalente a `dynamicTools` e as capacidades de cliente
  (`fs`, `terminal`) **não** são anunciadas (Q3). Portanto, na fase 3, nada de
  `linear_graphql`, `github_api` e afins no caminho ACP — gap explícito e aceito.
  **MCP local não é implementado nesta fase**; expor as ferramentas do tracker via
  `session/new.mcpServers` pode ser analisado **depois**, como caminho para
  client-side/dynamic tools, em ADR próprio.
- **Sandbox (sem promessa):** o ACP não define política de sandbox/filesystem/rede.
  Portanto:
  1. o Symphony **não** oferece no caminho ACP o que oferece via
     `codex.thread_sandbox`/`turn_sandbox_policy`;
  2. `codex.approval_policy`, `thread_sandbox` e `turn_sandbox_policy` são
     lidos/validados como hoje, mas **não** são passados ao agente ACP (não
     existe campo);
  3. a documentação de configuração deve dizer isso explicitamente, sem prometer
     isolamento;
  4. mitigações efetivas são do projeto/plataforma (workspace dedicado, sem
     segredos no env do filho, sem privilégio, Draft PR, gates).

### 2.8 Erros, métricas e limites conhecidos

- Taxonomia de erro exposta: `:response_timeout`, `:turn_timeout`, `:port_exit`,
  `:turn_failed`, `:turn_cancelled`, `:approval_required`,
  `:turn_input_required`, mais os novos específicos de ACP:
  `{:acp_version_unsupported, version}`, `{:acp_response_error, error}` e
  `{:acp_auth_required, methods}`. `auth_required` **bloqueia** a execução e
  exige ação humana (Q5, §2.2).
- **Decisão Q6 (métricas/tokens): ausência não é zero.** A ausência de dados de
  uso no ACP **não pode** ser convertida em zero "real": o caminho ACP deve
  representar o dado como **indisponível/ausente**, e **nunca** fabricar métrica
  (nem contar 0 como se fosse uso medido). Consequência prática: o adaptador ACP
  não emite evento de uso sintético; se o estado/dashboard atuais não souberem
  expressar ausência sem ambiguidade (hoje os contadores existem no estado e o
  dashboard exibe números), isso é **dívida registrada** a resolver **antes da
  integração real do Cline** (fase 4), e não um comportamento aceitável para a
  fase de integração real.
- Limites declarados na fase 3: sem sandbox (D15), sem ferramentas do cliente nem
  do tracker (D11/D12 — Q4), sem elicitation (D14), métricas de uso possivelmente
  indisponíveis (D27 — Q6), sem rate limits (D28), sem cancelamento gracioso
  (D18 — Q7), sem `session/load` (sessão nova a cada tentativa).


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
| `elicitation/create` (form/url), `elicitation/complete` | não anunciado (Q3); sem canal humano no run (Q5) |
| `session/load`, `session/resume`, `session/close`, `session/delete`, `session/list` | fora de escopo; cada tentativa abre sessão nova |
| `session/set_mode`, `modes`, `session/set_config_option`, `config_option_update` | perfis `read`/`dev`/`privileged` são conceito da plataforma, não do protocolo; mapear é decisão futura |
| `terminal/*`, `fs/*` | capacidades de cliente que ampliariam privilégio; **não** anunciadas (Q3) |
| `mcpServers` | caminho futuro para ferramentas do tracker; **não** usado na fase 3 (Q4) |
| `$/cancel_request`, `session/cancel` | sem canal de cancelamento no runner atual; gracioso adiado (Q7) |
| `usage_update` (custo/contexto) | mapeamento fino pendente (D27); ausência deve aparecer como **indisponível**, nunca como zero (Q6) |
| `authMethods`/`authenticate`/`logout` | autenticação do agente é manual e fora do Symphony; `auth_required` bloqueia com handoff (Q5) |
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
`session_id` de log — que, no caminho ACP, é o identificador **interno/sintético**
descrito em §2.3 (não é identidade do protocolo).


## Consequências

- **Positivas:** o comportamento observável do Symphony é preservado (mesmos
  eventos, mesmos campos, mesma política de retry/stall/bloqueio); o caminho Codex
  não muda; a fase 3 é validável com um agente ACP falso, sem Cline, sem modelo e
  sem credencial; os gaps ficam declarados em vez de escondidos atrás de uma
  tradução otimista.
- **Negativas / custos:** no caminho ACP o Symphony tem menos controle e menos
  observabilidade do que no Codex (sem sandbox, sem uso/tokens confiáveis, sem
  ferramentas do cliente nem do tracker, sem cancelamento gracioso); o executor
  ACP recebe menos contexto institucional (sem `title`, sem ferramentas do
  tracker, sem elicitation); a dívida de nomes `codex_*` permanece; a
  representação de métricas ausentes precisa ser resolvida antes da integração
  real do Cline (Q6); a implementação precisa manter um segundo protocolo sob
  teste.
- **Obrigações:** implementar somente o que está nesta decisão; toda extensão
  (MCP local, cancelamento gracioso, `session/load`, elicitation, modos) exige ADR
  novo; registrar no PR a release exata do schema ACP usada; cobrir o caminho ACP
  com o **agente falso determinístico** antes de qualquer executor real (Q10);
  atualizar [../acp-analysis.md](../acp-analysis.md) se a spec mudar de forma
  material (versão nova do schema v1 ou estabilização do v2); registrar
  divergências de arquivo upstream em [../divergences.md](../divergences.md);
  **nunca** converter ausência de dado em zero (Q6) e **nunca** afirmar que
  `Port.close` é cancelamento gracioso de sessão ACP (Q7).

## Alternativas descartadas

| Alternativa | Por que foi descartada |
|---|---|
| Traduzir `codex.approval_policy` para uma política global de permissão ACP | não existe política global no ACP; a decisão é por chamada, e inventar um mapeamento daria falsa sensação de controle |
| Anunciar `fs`/`terminal` para compensar a ausência de `dynamicTools` | troca um gap por uma ampliação de privilégio (o agente passaria a executar arquivos/comandos no processo do Symphony), sem ganho de isolamento |
| Anunciar `elicitation.form` e responder automaticamente | a resposta estruturada exigiria decisão humana; auto-responder seria pior que não anunciar (o agente agiria com informação fabricada) |
| Auto-aprovar permissões por padrão (paridade com `approval_policy: never` do `WORKFLOW.md` de exemplo) | aprovado não é padrão seguro para um executor sem sandbox; fica como configuração explícita (Q2) |
| Recusar a resposta ao `session/request_permission` e seguir esperando operador | a spec exige resposta do cliente; deixar pendente trava o agente e o stall só cortaria depois |
| Implementar `session/load` para "continuar" a sessão após retry | o ACP só oferece `loadSession` se o agente suportar, e o Symphony hoje **não** tenta retomar thread em retry (abre nova); uniformizar exigiria mudança de comportamento upstream |
| Assumir que tokens virão em formato Codex (`tokenUsage.total`) | inventaria contadores; o correto é representar uso como **indisponível** e registrar a dívida (D27, Q6) |
| Copiar a especificação ACP para dentro do repositório | a spec é externa e versionada por ela mesma; duplicar cria fonte divergente |

## Implementação

Estado: **pendente** (nada implementado). Este ADR descreve o mapeamento a ser
implementado em `SymphonyElixir.Executor.Acp`, validado por um **agente ACP falso
determinístico**, depois do merge deste ADR. As decisões humanas de Q1–Q10 já
estão incorporadas (§2.2 a §2.8 e
[ADR-0001](0001-executor-abstraction.md) §Decisões humanas incorporadas): **não há
questão aberta bloqueando a fase 3**.

Sequência prevista para a fase 3 (plataforma: "runner ACP com fake"):

1. abstração e delegação Codex ([ADR-0001](0001-executor-abstraction.md)) com
   testes de paridade, partindo da `main` integrada;
2. implementar o cliente ACP conforme §2.1–§2.8, com `@spec` em todo `def`
   público (`mix specs.check`), anunciando o mínimo de capacidades (Q3) e sem
   autoaprovação (Q2);
3. escrever o agente ACP falso (script executável que fala JSON-RPC por linha) e
   os testes de: handshake/negociação de versão, `session/new`, turno completo,
   silêncio, morte do processo, frame malformado, `session/request_permission`
   (recusa/bloqueio), `stopReason: cancelled` e `stopReason` de falha;
4. registrar divergências, atualizar `elixir/README.md` no que mudou e rodar
   `make -C elixir all`.

**Cline não entra na fase 3** (Q10): nenhum teste desta fase depende do Cline,
de modelo, de credencial ou de rede; o executor inicial é o fake determinístico.
Cline (fase 4) e DeepSeek (fase 5) pertencem ao roadmap da plataforma.

Fora do escopo explícito (fases ≥ 4, cada um exigindo decisão própria): MCP local
para ferramentas do tracker, cancelamento gracioso, `session/load`,
elicitation/`requestUserInput` interativo, modos/config options, representação de
métricas ausentes no dashboard (dívida Q6), aprovação humana fora de banda e
protocolo ACP v2.
