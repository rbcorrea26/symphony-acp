# ADR-0004 — cliente ACP e execução de turnos (incremento 2 da fase 3)

- **Status:** aceito
- **Data:** 2026-09-28
- **Decisores:** arquitetura do fork (rbcorrea26)
- **Relacionado a:** [0001-executor-abstraction.md](0001-executor-abstraction.md),
  [0002-acp-protocol-mapping.md](0002-acp-protocol-mapping.md),
  [0003-phase3-executor-abstraction-scope.md](0003-phase3-executor-abstraction-scope.md),
  [../acp-analysis.md](../acp-analysis.md) §2.5, §7 e §9,
  [../divergences.md](../divergences.md), `SPEC.md` §5.3.6, §6.3 e §10

## Contexto

O [ADR-0003](0003-phase3-executor-abstraction-scope.md) registrou o incremento 1 da
fase 3 (abstração + `executor.kind` + executor fake de teste) e deixou explícito que
o **agente ACP falso por stdio** só entra junto com o cliente ACP real. Este ADR
registra o incremento 2: `SymphonyElixir.Executor.Acp`, o cliente ACP mínimo e o
agente ACP fake determinístico que prova o caminho ACP **dentro** do Symphony, sem
Cline, sem modelo, sem rede e sem credencial.

### Especificação ACP consultada nesta implementação

| Item | Valor |
|---|---|
| Documentação oficial | `https://agentclientprotocol.com` (`Protocol v1`: Overview, Initialization, Session Setup, Prompt Turn, Tool Calls, Authentication, Transports) |
| Repositório oficial | `https://github.com/agentclientprotocol/agent-client-protocol` |
| Data da consulta | **2026-09-28** |
| Versão de protocolo | **1** (inteiro MAJOR negociado em `initialize.protocolVersion`); v2 continua *draft* (`schema-v2.0.0-alpha.*`) e não é alvo |
| Release de schema usada | **`schema-v1.23.0`** (`schema.json` do release, 247.168 bytes, baixado da release oficial; mesma tag registrada em [0002](0002-acp-protocol-mapping.md) em 2026-09-27) |
| Diferença em relação à análise anterior | **nenhuma material**: a última release v1 continua sendo `schema-v1.23.0`; `initialize`/`session/new`/`session/prompt`, os 11 variantes de `session/update`, os cinco `stopReason` (`end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`), `PermissionOptionKind` (`allow_once`/`allow_always`/`reject_once`/`reject_always`), `RequestPermissionOutcome` (`selected`/`cancelled`), `usage_update` (`used`/`size`/`cost`) e o código de erro `-32000` ("Authentication required") permanecem como descritos no ADR-0002 |

Detalhes verificados no schema e usados pelo código: `NewSessionRequest` exige `cwd`
e `mcpServers`; `InitializeRequest` exige apenas `protocolVersion` e trata
capability omitida como *unsupported*; o transporte stdio é JSON-RPC delimitado por
`\n`, sem *embedded newlines*, e `stderr` é o canal **livre** para log do agente —
que o cliente ACP mantém fora do canal de protocolo (§4.10).

### O que o incremento 1 não tinha

1. **`acp.*` sem comportamento** (ADR-0003 §Contexto item 3): agora existe comando,
   política de permissão e timeouts reais por trás.
2. **`Executor.validate_config/1` só resolvia o *kind*.** Preflight de
   `acp.command` exige ler o bloco `acp`, que vive no `%Config.Schema{}` completo.
3. **Nenhum caminho de agente externo ACP**: o transporte, o *framing*, o parser
   tolerante, a identidade de sessão/turno, a política de permissão e o mapeamento de
   eventos precisavam de dono.

## Decisão

### 4.1 Dois módulos, uma fronteira cada

- `SymphonyElixir.ACP.Client` é o **cliente ACP mínimo**: lança o processo, fala
  JSON-RPC por linha, implementa `initialize`, `session/new`, `session/prompt` com
  `session/update` e `session/request_permission`, e devolve resultados de
  **protocolo** (`stopReason` cru, erros ACP). Ele não conhece Symphony: nada de
  orquestração, de `Issue`, de estado de tracker nem de política de turnos.
- `SymphonyElixir.Executor.Acp` é o **executor**: lê `Config`, valida o workspace,
  abre/encerra a sessão, compõe a identidade sintética do turno, traduz eventos ACP
  para o vocabulário que o orquestrador já consome e mapeia `stopReason`/erros para
  `{:ok, ...}`/`{:error, ...}` do behaviour.
- O behaviour `SymphonyElixir.Executor` **não muda** na superfície de sessão:
  `start_session/2`, `run_turn/4`, `stop_session/1` continuam sendo exatamente o que
  o `AgentRunner` usa, e o runner não aprendeu JSON-RPC, ACP, `initialize`,
  `session/new` ou `session/prompt`.

### 4.2 Transporte e parser

- Lançamento no mesmo formato do caminho Codex (`Port.open` de `bash -lc`, `cd` no
  workspace validado, env saneado removendo `secret_environment_names`), com **uma
  diferença deliberada**: o lançamento ACP **não** usa `:stderr_to_stdout` (§4.10);
  remoto via `SSH.start_port` com `stderr_to_stdout: false` e o comando
  `cd '<workspace>' && unset SECRETS && exec <command>`.
- *Framing* por linha com reassemblagem: `line_bytes` é o tamanho máximo de chunk que
  o port entrega; frames maiores chegam em `{:noeol, ...}` e são remontados (o valor
  é injetável só em teste, para exercitar o caminho sem depender de sorte de I/O).
- Parser **tolerante** (decisão D22 do ADR-0002) **apenas para o `stdout`**, o único
  canal que o cliente lê: linha não-JSON vira log (`debug`, ou `warning` quando
  contém termo de erro) e não interrompe o turno; JSON inválido que *parece* frame
  vira evento `:malformed`; JSON sem `id` nem `method` vira `:notification` (payload
  íntegro) e mantém a conexão viva. Nada disso pode ser originado em `stderr`
  (§4.10).
- Erros de protocolo expostos com a taxonomia do ADR-0002
  (`{:acp_response_error, error}`, `{:acp_version_unsupported, version}`,
  `{:acp_auth_required, methods}`, `:response_timeout`, `:turn_timeout`,
  `{:port_exit, status}`) mais o novo `{:acp_unsupported_request, method}` (§4.5).

### 4.3 Identidade de sessão e de turno

- `sessionId` devolvido por `session/new` é a **única identidade de protocolo**; é o
  valor enviado em `session/prompt`.
- O identificador que o Symphony usa em logs/eventos/`turn_count` continua sendo o
  composto `"<sessionId>-<n>"`, com `n` = contador **local** 1-based. Ele **nunca** é
  enviado ao agente como se fosse identidade ACP: o teste do runner verifica que o
  trace do agente contém apenas `sessionId=sess-fake-acp` em todos os turnos.
- O contador vive em um ref `:atomics` dentro do termo de sessão opaco, que o
  `AgentRunner` só repassa. Motivo: o termo de sessão precisa sobreviver a várias
  chamadas de `run_turn/4` sem introduzir um processo dedicado de executor — o
  ADR-0001 rejeitou exatamente essa supervisão extra, porque o `try/after` da Task do
  worker já é dono do ciclo de vida.
- **Timeout**: `initialize`/`session/new` usam `codex.read_timeout_ms`;
  `session/prompt` é request longa e **nunca** usa timeout de resposta — vale o
  silêncio máximo entre frames (`codex.turn_timeout_ms`, reiniciado a cada frame).
  Reuso de chaves `codex.*` = dívida de nomeação já registrada (Q1).

### 4.4 Eventos emitidos (vocabulário preservado)

- `:session_started` (`session_id` sintético, `acp_session_id`, `turn_id`);
- `:notification` para cada `session/update` (payload = params ACP íntegros) e para
  notificações/métodos desconhecidos; `:malformed` para frame JSON inválido;
- `:turn_completed` (`stopReason: end_turn`), `:turn_failed` (outros `stopReason`),
  `:turn_cancelled` (`cancelled`) e `:turn_ended_with_error` para falhas de
  transporte/protocolo (paridade com o caminho Codex);
- `:approval_required` / `:approval_auto_approved` para `session/request_permission`;
- **diferença deliberada do cliente Codex:** no caminho ACP o turno recusado por
  permissão emite `:approval_required` e **nada depois**, para que
  `last_codex_event` permaneça `:approval_required` e o orquestrador **bloqueie** a
  issue (o cliente Codex ainda emite `:turn_ended_with_error`, o que mascararia o
  bloqueio);
- `codex_app_server_pid` continua sendo o campo do pid do processo filho (nome
  interno preservado, Q8) — o ACP não carrega pid no protocolo.

### 4.5 Permissão, autenticação e entradas não suportadas

- **Permissão (`session/request_permission`) — fail closed (Q2).** Com
  `acp.auto_approve_requests: false` (default) o cliente responde a opção de **menor
  escopo** disponível: `reject_once`, senão `reject_always`, senão o *outcome*
  `cancelled`. Em seguida emite `:approval_required` e encerra o turno com
  `{:error, {:approval_required, payload}}`. A request **nunca** fica pendente (o
  agente ficaria esperando indefinidamente).
- Com `acp.auto_approve_requests: true` (configuração explícita, testada) o cliente
  seleciona `allow_once`, senão `allow_always`, e **continua** o turno; se não houver
  opção de aprovação, ele ainda cancela e bloqueia o turno. Não existe equivalência
  implícita com `codex.approval_policy: never`: são mecanismos diferentes (decisão por
  chamada × política global do Codex).
- **Autenticação (Q5).** Nenhuma credencial é lida, pedida ou armazenada. Resposta
  `-32000` em `initialize` (ou em qualquer request) vira `{:error, {:acp_auth_required,
  methods}}` — os métodos vêm de `error.data.authMethods` quando o agente os envia — e
  a execução **bloqueia** até ação humana (`cline auth` no caso do Cline, fase 4).
- **Elicitation e demais métodos de cliente (Q3/Q4).** O cliente anuncia
  `clientCapabilities: {}`: nada de `fs`, `terminal`, `elicitation` nem `additionalDirectories`.
  Se o agente chamar mesmo assim um método que o cliente não implementa, a resposta é
  um erro JSON-RPC explícito (`-32601`, "Unsupported ACP client method: <method>") e o
  turno/sessão falha com `{:error, {:acp_unsupported_request, method}}`. Nunca se
  inventa resposta humana nem se emula capability não anunciada.

### 4.6 Configuração e preflight

- `acp.command` (string, **sem default**; obrigatória quando `executor.kind: acp`) e
  `acp.auto_approve_requests` (boolean, default `false`).
- Preflight: `Executor.validate_config/1` passa a receber o `%Config.Schema{}` completo
  e delega para um callback **opcional** `validate_config/1` da implementação
  (espelhando `Tracker.validate_config/1`). `Executor.Acp` exige `acp.command`
  não-vazio e falha com `{:error, :missing_acp_command}`; `Executor.Codex` não declara
  o callback e segue `:ok`. O cliente também recusa lançar sem comando, com o mesmo
  nome de erro (defesa em profundidade).
- `codex.*` continua intacto (defaults, validações e preflight); workflow sem `acp`
  segue válido byte a byte; `executor.kind` continua default `codex`.

### 4.7 Encerramento e cancelamento (Q7 — limitação explícita)

- `stop_session/1` fecha o **processo e o transporte** (`Port.close`, idempotente e
  tolerante a corrida com a saída do processo). Isso **não** é `session/cancel`,
  `session/close` nem qualquer encerramento gracioso do ACP: nenhuma notificação de
  cancelamento é enviada e o agente não tem chance de terminar trabalho de forma
  ordenada. Cancelamento gracioso continua adiado para a integração real (fase ≥ 4),
  com ADR próprio.

### 4.8 Token accounting (Q6)

- `usage_update` do ACP é repassado como `:notification` com o payload íntegro
  (`used`/`size`/`cost`) e **não** vira contador: nenhum evento recebe chave `:usage` e
  nenhum campo de token é fabricado. A ausência de métrica confiável continua sendo
  dívida registrada para antes da integração real do Cline.

### 4.9 Fake ACP determinístico (validador da fase 3)

- O agente fake é um **processo externo** de teste (`bash` + `jq`), escrito pelo
  próprio teste, que fala o transporte ACP real. Ele é programado por
  `fake-acp.plan` no workspace e grava o que cruzou o fio em `fake-acp.trace`, e o
  harness apaga o `test_root` antes de usá-lo (o número do diretório é único apenas
  dentro de uma VM, então um run interrompido não pode vazar trace antigo para o
  run seguinte).
- Ele não usa internet, Cline, DeepSeek, credenciais, MCP, capability de filesystem
  nem terminal, e vive só na suíte de testes: o Symphony o seleciona pelo
  `acp.command` configurado no teste, nunca por `executor.kind: fake`.
- Cenários cobertos: `initialize` (ok, versão incompatível, `auth_required` com e sem
  métodos, resposta sem `protocolVersion`, sem `result`, erro interno, silêncio,
  crash, notificação desconhecida, request não suportado, frame JSON solto), `session/new`
  (ok/erro/sem `sessionId`), turnos (ok, múltiplas mensagens, falha, cancelamento,
  silêncio, crash, permissão, permissão sem allow, permissão sem params, request não
  suportado, notificação desconhecida, frame malformado, ruído não-JSON, JSON solto,
  resultado inválido, erro do agente, `usage_update`), múltiplos turnos na mesma
  sessão, env sem segredo do tracker, execução por `ssh` (worker remoto), separação
  de `stdout`/`stderr` (`stderr_probe`/`stderr_silent` em `initialize`,
  `session/new` e turnos) e teardown.
- O teste de ponta a ponta é `AgentRunner → Executor.Acp (por executor.kind) →
  stdio/JSON-RPC → agente fake → eventos → continuação → teardown`.

### 4.10 Separação de `stdout` e `stderr` (correção registrada nesta PR)

- **Causa raiz.** O lançamento usava `:stderr_to_stdout` (paridade mecânica com o
  caminho Codex), então o `stderr` do agente entrava no **mesmo canal** do protocolo.
  Com os dois streams fundidos a origem do conteúdo se perdia, e a única defesa era o
  parser tolerante (D22) — insuficiente: um log de `stderr` com forma de frame
  (`{"jsonrpc":"2.0","id":N,"result":...}`, um `{"level":"error",...}` ou um
  `session/update` fabricado) seria indistinguível de mensagem ACP e podia satisfazer
  uma resposta pendente ou virar `:notification`/`:malformed`.
- **Correção.** `stdout` é o **único** canal consumido pelo *framing*/parser; o
  lançamento ACP deixa de pedir o merge:
  - **local**: `Port.open` do `bash -lc` sem `:stderr_to_stdout` — o processo filho
    herda o `stderr` do nó, então o log do agente continua observável no sink de
    diagnóstico do Symphony (console/journald do serviço) sem cruzar o protocolo;
  - **remoto**: `SSH.start_port/3` recebe `stderr_to_stdout: false` (parâmetro
    **aditivo** do módulo, default inalterado). O `ssh` já encaminha o `stderr` do
    comando remoto para o seu próprio `stderr`, que o nó herda — a separação vale
    igualmente com `worker_host`.
- **Consequência declarada.** O conteúdo de `stderr` não passa mais pelo caminho de
  log do cliente: não há classificação `debug`/`warning` nem truncamento por linha
  feito pelo Symphony para esse canal (o sink é do serviço/SO). O limite existente
  `@max_stream_log_bytes` continua valendo para o único caso em que o cliente
  registra linha bruta — não-JSON em **`stdout`** (violação da spec pelo agente, que
  o parser tolera por decisão D22). Segredos não entram por aqui: o ambiente do filho
  já vai sem `secret_environment_names`.
- **Provas (testes determinísticos, sem `sleep` arbitrário).** O agente fake ganhou
  as diretivas `stderr_probe` e `stderr_silent`, que escrevem em `stderr` texto
  comum, JSON válido (`{"level":"error",...}`), uma notificação `session/update` e
  uma **resposta JSON-RPC completa para o id da request pendente naquele instante**
  — registrando um trace para que a asserção não passe em vazio. Os testes então
  provam que `initialize` continua negociando a versão do `stdout` (não a `2` do
  `stderr`), `session/new` não aceita `sess-from-stderr`, o turno mantém
  `stopReason: end_turn` (não o `refusal` do `stderr`) e que os únicos eventos são os
  do `stdout` (nenhum `:notification`/`:malformed` de origem `stderr`). Duas provas
  por silêncio fecham o caso: `stderr_silent` faz o `initialize` terminar em
  `:response_timeout` e o turno em `:turn_timeout`, ou seja, a resposta escrita em
  `stderr` **não** satisfaz a request pendente. O caminho remoto é exercitado pelo
  mesmo fake através do `ssh` falso, e `ssh_test.exs` fixa as duas metades do
  parâmetro (`stderr` fora do port quando solicitado; merge preservado no default).

## Consequências

- **Positivas:** a fase 3 fica verificável no repositório: o ciclo de turnos do
  Symphony roda por ACP de verdade, com agente externo, sem Cline/modelo/rede/segredo;
  o caminho Codex continua sendo o default e não foi tocado; protocolo e orquestração
  ficam em módulos separados; o canal de protocolo é **único** (`stdout`), com o
  `stderr` do agente fora do parser e ainda observável como diagnóstico (§4.10); os
  limites (sem sandbox ACP, sem capability de cliente, sem elicitation, sem
  cancelamento gracioso, sem métrica de token) estão declarados e testados em vez de
  escondidos atrás de tradução otimista.
- **Negativas / custos:** o fork agora mantém **dois** clientes de protocolo sob teste
  (Codex app-server e ACP) e um agente fake a mais na suíte; o caminho ACP observa menos
  que o Codex (sem pid de protocolo, sem tokens, sem ferramentas do tracker); a
  nomenclatura interna `codex_*` continua (dívida Q8); timeouts ainda moram em
  `codex.*` (dívida Q1); o `stderr` do agente não é classificado nem truncado pelo
  cliente, porque não passa pelo caminho de log do Symphony (§4.10).
- **Obrigações:** manter a paridade do caminho Codex sob qualquer mudança futura;
  registrar divergências de arquivo upstream em [../divergences.md](../divergences.md);
  nunca converter ausência de métrica em zero (Q6) nem afirmar que `Port.close` é
  cancelamento gracioso (Q7); se a spec ACP mudar de forma material (nova versão do
  schema v1 ou estabilização do v2), atualizar [../acp-analysis.md](../acp-analysis.md)
  antes de mudar comportamento.

## Alternativas descartadas

| Alternativa | Por que foi descartada |
|---|---|
| Implementar ACP dentro de `Codex.AppServer` | reescrever o arquivo upstream mais volátil do caminho de execução, com risco de regressão no Codex (já descartado no ADR-0001) |
| Um `GenServer`/processo dedicado por sessão ACP só para guardar o contador de turno | adiciona supervisão e ciclo de vida sem necessidade; o `try/after` da Task do worker já é dono da sessão (ADR-0001) — o contador em `:atomics` dentro do termo opaco resolve o mesmo problema sem processo |
| Auto-aprovar por default (paridade com `approval_policy: never` do exemplo) | aprovado não é default seguro para um executor sem sandbox; `acp.auto_approve_requests` é explícito, testado e default `false` (Q2) |
| Deixar a request de permissão sem resposta e seguir esperando operador | a spec exige resposta; travaria o agente até o stall/timeout |
| Responder `fs`/`terminal`/`elicitation` "para destravar" um agente | amplia privilégio e cria resposta fabricada; o correto é erro explícito + falha do turno |
| Emitir evento de uso sintético a partir de `usage_update` | fabricaria métrica (Q6); ausência de dado continua ausência |
| Escrever o fake ACP em Elixir/Lua/Python embutido | precisaria de um parser JSON próprio ou de runtime extra; `bash` + `jq` (já usado pelo repositório no workflow de PR) fala o protocolo real sem inventar dependência de runtime de linguagem |
| Enviar `session/cancel` no teardown e chamar isso de cancelamento gracioso | não existe canal de cancelamento no runner atual e `Port.close` não é `session/cancel` (Q7) |
| `executor.kind: fake` para selecionar o agente ACP fake | criaria caminho de produção que aceita um executor falso; o fake entra por `acp.command` só nos testes (ADR-0003 §3.1) |

## Implementação

Estado: **implementado** (incremento 2 da fase 3). Arquivos:

| Arquivo | Tipo | Mudança |
|---|---|---|
| `elixir/lib/symphony_elixir/acp/client.ex` | novo | cliente ACP mínimo por stdio: lançamento (**sem** merge de `stderr`), *framing*, `initialize`, `session/new`, `session/prompt`, permissão, erros de protocolo, teardown |
| `elixir/lib/symphony_elixir/executor/acp.ex` | novo | executor ACP: config, validação, eventos, identidade sintética de turno, mapeamento de `stopReason` |
| `elixir/lib/symphony_elixir/executor.ex` | upstream alterado | `"acp"` no mapa, callback opcional `validate_config/1`, `validate_config/1` recebendo o `%Schema{}` |
| `elixir/lib/symphony_elixir/config/schema.ex` | upstream alterado (aditivo) | bloco `acp` (`command`, `auto_approve_requests` default `false`) |
| `elixir/lib/symphony_elixir/config.ex` | upstream alterado | preflight chama `Executor.validate_config(settings)` |
| `elixir/lib/symphony_elixir/ssh.ex` | upstream alterado (aditivo) | `start_port/3` aceita `stderr_to_stdout: false` para o caminho ACP manter o `stderr` remoto fora do port; o default (`:stderr_to_stdout`) preserva o comportamento do Codex app-server |
| `elixir/test/symphony_elixir/acp_test.exs` | novo | agente ACP fake por stdio + config, cliente, executor, separação de `stdout`/`stderr` e o teste de ponta a ponta do `AgentRunner` |
| `elixir/test/symphony_elixir/executor_test.exs` | fork alterado | superfície do behaviour (3 callbacks + `validate_config` opcional) e nova assinatura do preflight |
| `elixir/test/symphony_elixir/ssh_test.exs` | upstream alterado (aditivo) | os dois comportamentos do novo parâmetro de `start_port/3` (`stderr` separado quando pedido; merge no default) |
| `elixir/test/support/test_support.exs` | upstream alterado (aditivo) | `acp_command`/`acp_auto_approve_requests` no harness |
| `elixir/README.md` | upstream alterado | configuração ACP real, limites declarados, separação de streams e dependência de teste (`jq`) |

### O que continua igual no upstream

- `SymphonyElixir.Codex.AppServer` e `SymphonyElixir.Codex.DynamicTool` **não foram
  alterados** em nenhuma linha; `Executor.Codex` continua delegação pura.
- `codex.command`, `approval_policy`, `thread_sandbox`, `turn_sandbox_policy`,
  `turn_timeout_ms`, `read_timeout_ms` e `stall_timeout_ms` mantêm defaults e
  validações; workflow sem bloco `executor`/`acp` continua válido sem edição.
- `AgentRunner`, `Orchestrator`, `Workspace` e `StatusDashboard` não foram alterados
  nesta PR: a política de turnos, hooks, retry/backoff, stall, reconciliação e o
  payload do dashboard seguem como no incremento 1 (Q8 preservado).
- `SPEC.md` e `elixir/WORKFLOW.md` **não foram alterados**: a extensão é superset e não
  conflita com o contrato, o exemplo de workflow do repositório continua sendo o do
  Codex e a referência de configuração do fork vive em `elixir/README.md` (mesma
  escolha do incremento 1).
- Testes existentes: nenhum teste upstream foi removido ou enfraquecido; os ajustes são
  no teste do fork (`executor_test.exs`), exigidos pela superfície nova do preflight.
- Cobertura: 100% mantida, **sem** adicionar módulo novo a `ignore_modules`.

### Dívidas registradas por este incremento

- cancelamento gracioso ACP (`session/cancel`, `session/close`) não existe: o que há é
  teardown de processo/transporte (Q7);
- timeouts do caminho ACP continuam vindo de `codex.read_timeout_ms`/
  `codex.turn_timeout_ms` (Q1);
- nomes internos `codex_*` preservados (Q8);
- métrica de uso ACP não representável no dashboard sem ambiguidade (Q6) — resolver
  antes da integração real do Cline;
- o fake ACP depende de `bash` e `jq` no ambiente de teste (declarado em
  `elixir/README.md` §Testing);
- o `stderr` do agente é encaminhado ao sink de diagnóstico do nó e **não** passa pela
  classificação/truncamento que o cliente aplica a linha não-JSON em `stdout`: reter,
  rotacionar ou limitar esse canal é responsabilidade do serviço/SO (§4.10);
- atualizar o roadmap/manifests da plataforma (status da fase 3 e SHA do fork) é PR no
  `agentic-dev-environment`, não neste repositório.
