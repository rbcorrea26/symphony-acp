# Cline real como agente ACP (fase 4): verificação e estado

Este documento registra o **estado medido** do Cline CLI do runtime isolado falando
ACP com o caminho já implementado no fork (`AgentRunner` → `Executor.Acp` →
`ACP.Client` → `stdio`/JSON-RPC), o resultado do *spike* feito antes de qualquer
alteração de código e o **blocker** que mantém a fase 4 pendente.

Ele não duplica decisões da plataforma (executor inicial, modelo, gates, runtime:
`rbcorrea26/agentic-dev-environment`) nem o mapeamento de protocolo
([adr/0002](adr/0002-acp-protocol-mapping.md)) e a implementação do cliente
([adr/0004](adr/0004-acp-client-implementation.md)); referencia os dois. Também não
duplica a análise documental ([acp-analysis.md](acp-analysis.md)).

## 1. Status

| Item | Estado |
|---|---|
| Symphony como **cliente ACP** (`SymphonyElixir.ACP.Client`) | implementado (fase 3) |
| Cline CLI como **agente ACP** (`acp.command`) | **compatível** no handshake; turno real **bloqueado** |
| Fase 4 (integração Cline) | **pendente** — dependência humana de autenticação |
| DeepSeek | fora desta fase (fase 5 da plataforma); não configurado aqui |

O que ficou **provado** nesta verificação: o cliente fala com o Cline real
(`initialize` negociado, frames aceitos, `stderr` fora do parser) e o `session/new`
real devolve um erro ACP explícito de autenticação, que o cliente já mapeava. Não foi
encontrada incompatibilidade de protocolo; o que falta é **autenticação do runtime
isolado**, que a plataforma decidiu ser passo humano.

O que **não** ficou provado — e por isso a fase 4 continua pendente: um turno do
`AgentRunner` com alteração verificável em workspace descartável
(`session/prompt`, `session/update`, `stopReason`, teardown).

## 2. Runtime verificado

Ambos medidos no ambiente local, sem exibir segredo:

| Item | Valor medido |
|---|---|
| versão executada pelo wrapper | `3.0.65` (`cline --version` pelo wrapper do pipeline) |
| wrapper | `~/automation/bin/cline` (injeta `--data-dir` do pipeline e o Node do mise) |
| data-dir isolado | `~/automation/state/cline` — **vazio** (nenhuma credencial persistida) |
| suporte a ACP no `--help` local | sim: `--acp  Run in Agent Client Protocol (ACP) mode for editor integration` |
| transporte | `stdio`: `stdout` = protocolo, `stderr` = diagnóstico (`[acp] starting ACP mode over stdio…`) |

O wrapper é o único Cline usado: ele fixa `--data-dir` no estado do pipeline, de modo
que a instalação pessoal do usuário (`~/.cline`) fica intocada — e **não** é usada como
fonte de credencial (ver §5).

## 3. Handshake real medido (antes de qualquer alteração de código)

Spike mínimo: o processo foi lançado **exatamente como o `acp.command` o lança**
(`~/automation/bin/cline --acp`, com o `cwd` do workspace de teste) e recebeu os frames
que `SymphonyElixir.ACP.Client` envia, byte a byte — inclusive sem o campo `jsonrpc`
(nenhum adaptador, nenhum patch).

`initialize` (enviado: `protocolVersion: 1`, `clientCapabilities: {}`, `clientInfo` do
Symphony; resposta do agente, resumida):

```json
{"protocolVersion":1,
 "agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true,"audio":false,"embeddedContext":false}},
 "agentInfo":{"name":"cline","version":"3.0.65"},
 "authMethods":[{"id":"cline","name":"Sign in with Cline"},
                {"id":"cline-pass","name":"Sign in with ClinePass"},
                {"id":"openai-codex","name":"Sign in with ChatGPT Subscription"}]}
```

`session/new` (enviado: `cwd` do workspace + `mcpServers: []`):

```json
{"jsonrpc":"2.0","id":2,
 "error":{"code":-32000,"message":"Authentication required: Call authenticate before starting a session"}}
```

Fatos derivados:

1. o framing do cliente é aceito pelo Cline real (JSON-RPC 2.0 newline-delimited);
2. a versão negociada é `1`, a mesma que o cliente envia;
3. o `stderr` do agente traz apenas diagnóstico (`[acp] starting ACP mode over stdio…`)
   e nunca entrou no parser;
4. `session/new` é o ponto exato do gate de autenticação, e o erro `-32000` é
   mapeado pelo cliente para `{:acp_auth_required, methods}` (aqui `methods` vem vazio
   porque a resposta não traz `data.authMethods`);
5. nenhuma capability do cliente foi exigida para o handshake (nada de `fs`,
   `terminal`, `elicitation`, `session/load`, `additionalDirectories` ou MCP).

## 4. Incompatibilidades encontradas

Nenhuma lacuna de protocolo foi demonstrada até o gate de autenticação: `initialize`
e a interpretação de `session/new` (inclusive o erro de autenticação) já funcionavam
sem alteração de código. Os eventos posteriores ao gate — `session/prompt`,
`session/update`, `session/request_permission` e `stopReason` — **não** puderam ser
medidos, porque dependem de sessão autenticada; não há, portanto, decisão de
compatibilidade tomada sobre eles. Se o Cline real exigir, na fase 4, uma capability
ou um método que o cliente não anuncia, isso entra como lacuna demonstrada (com
evidência, teste fake correspondente e registro), nunca por inferência.

## 5. Blocker humano: autenticação do runtime isolado

Estado sanitizado (presença/ausência, sem valor algum):

| Local | Conteúdo observado |
|---|---|
| `~/automation/state/cline` (data-dir do pipeline) | vazio — sem autenticação persistida |
| `~/.cline` (instalação pessoal do usuário) | existe, com estado próprio |
| `~/.config/agentic-dev-environment/env` | chaves de segredos da plataforma (nenhuma `CLINE_*`) |

Consequência: nenhuma credencial de Cline existe no runtime isolado. A plataforma
decidiu que a autenticação do Cline é manual e nunca automatizada
(`agentic-dev-environment/docs/architecture/adr/0003-cline-deepseek-como-executor-inicial.md`
§Obrigações; o `install.sh` lista o passo como manual), e a fase 3 decidiu que
`auth_required` bloqueia o turno
([adr/0002](adr/0002-acp-protocol-mapping.md) §2.2/§2.8, Q5). Copiar a credencial da
instalação pessoal para o data-dir do pipeline, ou passar segredo pelo `WORKFLOW.md`,
seria violar as duas decisões — por isso **não** foi feito, e o Symphony continua sem
guardar credencial do agente.

Passo humano necessário (executado pelo dono do ambiente, no runtime isolado):

```bash
~/automation/bin/cline auth
```

Depois disso, a verificação real reproduzível é:

```bash
cd ~/automation/src/symphony-acp/elixir && make cline-acp-e2e
```

## 6. Verificação reproduzível (opt-in)

`elixir/test/symphony_elixir/cline_acp_e2e_test.exs` segue o padrão de teste externo
já existente no repositório (`@moduletag`/`skip` por variável de ambiente + alvo
próprio no `Makefile`, como o `make e2e` do upstream):

```bash
cd elixir && make cline-acp-e2e
# ou
SYMPHONY_RUN_CLINE_ACP_E2E=1 mix test test/symphony_elixir/cline_acp_e2e_test.exs
```

| Variável | Papel |
|---|---|
| `SYMPHONY_RUN_CLINE_ACP_E2E=1` | gate: sem ela os dois testes são *skipped* (nunca rodam em `make all`, nunca em CI) |
| `SYMPHONY_CLINE_ACP_COMMAND` | `acp.command` do teste; default = wrapper do pipeline `$HOME/automation/bin/cline --acp` |

O que os dois testes fazem:

1. **handshake** — lança o Cline real, exige `initialize` com `protocolVersion: 1` e
   `agentInfo.name == "cline"` e exige que `session/new` responda **ou** uma sessão
   **ou** o bloqueio explícito de autenticação; qualquer outro desfecho (timeout, frame
   malformado, erro inesperado) falha o teste;
2. **turno real pelo runner** — cria um workspace **descartável** (diretório temporário
   com `git init`, um `answer.sh` que imprime `1` e o prompt determinístico), roda
   `AgentRunner.run/3` com `executor.kind: acp` **sem injeção de executor** (a seleção
   vem da configuração, como em produção) e só passa se:
   - o agente alterar o projeto descartável;
   - `bash answer.sh` imprimir exatamente `42` (validação determinística);
   - `git status --porcelain` mostrar `answer.sh` como o arquivo alterado;
   - o agente não sobrar como processo órfão depois do `stop_session/1`.

O workspace é sempre descartável e nunca um projeto consumidor, o clone canônico ou um
repositório deste repositório. Nenhum projeto consumidor real é tocado, nenhum
repositório GitHub é criado e o diretório é removido no fim do teste.

Se o Cline não estiver autenticado, o teste **falha com mensagem explícita** (não passa
em silêncio) e aponta o passo humano de §5 — a fase 4 continua pendente até o turno real
acontecer.

## 7. Permissões no teste

- O default global continua *fail-closed*: `acp.auto_approve_requests: false`.
- O teste escreve, **apenas no `WORKFLOW.md` descartável dele**,
  `acp.auto_approve_requests: true`, para que o Cline possa editar o próprio workspace
  sem bloquear o turno. É decisão por execução, não política geral, e não vale para
  projeto consumidor.
- O `--auto-approve` do próprio Cline **não** foi usado: o caminho de permissão do
  cliente ACP continua sendo exercitado pelo Symphony.
- Rejeição continua sendo o comportamento observável do default (coberto pelo agente
  ACP fake em `test/symphony_elixir/acp_test.exs`).

## 8. O que este documento não decide

- **modelo/provedor**: a fase 4 usa a autenticação que o runtime isolado já tiver; nada
  aqui canoniza provedor/modelo. DeepSeek é a fase 5 da plataforma e não foi
  configurado.
- **capabilities novas**: nenhuma foi anunciada ou implementada; o escopo mínimo da fase
  3 permanece.
- **`authenticate` ACP**: não implementado. O fluxo de autenticação continua sendo passo
  humano, como decidido.
- **cancelamento gracioso** (`session/cancel`/`session/close`): continua dívida
  conhecida; teardown de processo não é cancelamento de protocolo.

## 9. Referências

- [adr/0002](adr/0002-acp-protocol-mapping.md) (mapeamento ACP, Q2/Q5/Q7),
  [adr/0003](adr/0003-phase3-executor-abstraction-scope.md) e
  [adr/0004](adr/0004-acp-client-implementation.md) (cliente e executor ACP);
- [acp-analysis.md](acp-analysis.md) (análise documental e fontes oficiais do ACP);
- [divergences.md](divergences.md) (registro do diff em relação ao upstream);
- código: `elixir/lib/symphony_elixir/acp/client.ex`,
  `elixir/lib/symphony_elixir/executor/acp.ex`, `elixir/lib/symphony_elixir/agent_runner.ex`;
- teste: `elixir/test/symphony_elixir/cline_acp_e2e_test.exs` (opt-in) e
  `elixir/test/symphony_elixir/acp_test.exs` (determinístico, agente fake);
- plataforma: `agentic-dev-environment/docs/architecture/roadmap.md` (fase 4),
  `docs/architecture/adr/0002-*`, `docs/architecture/adr/0003-*`,
  `docs/security/permissions.md`.
