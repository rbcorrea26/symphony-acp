# Cline real como agente ACP (fase 4): verificação, resultado e estado

Este documento registra o **estado medido** do Cline CLI falando ACP com o caminho já
implementado no fork (`AgentRunner` → `Executor.Acp` → `ACP.Client` → `stdio`/JSON-RPC):
o *spike* feito antes de qualquer alteração de código, a autenticação manual que
desbloqueou a execução e o **turno real** que conclui a fase 4 no fork.

Ele não duplica decisões da plataforma (executor inicial, modelo, gates, runtime:
`rbcorrea26/agentic-dev-environment`) nem o mapeamento de protocolo
([adr/0002](adr/0002-acp-protocol-mapping.md)) e a implementação do cliente
([adr/0004](adr/0004-acp-client-implementation.md)); referencia os dois. Também não
duplica a análise documental ([acp-analysis.md](acp-analysis.md)).

## 1. Status

| Item | Estado |
|---|---|
| Symphony como **cliente ACP** (`SymphonyElixir.ACP.Client`) | implementado (fase 3) |
| Cline CLI como **agente ACP** (`acp.command`) | **verificado em turno real** |
| Fase 4 (integração Cline) no fork | **concluída** (turno real, efeito verificado, teardown) |
| Autenticação do agente | passo humano, feito **fora** do Symphony; dependência do runtime (§5) |
| DeepSeek (provedor inicial, fase 5) | **provado em turno real**: `provider=deepseek` e `model=deepseek-v4-flash` conferidos no registro de sessão do agente; teste opt-in pago `make cline-deepseek-e2e` (§8) |

Provado nesta verificação: `initialize`, `session/new`, `session/prompt` e
`session/update` reais; resposta real do modelo; alteração real no workspace descartável
com validação determinística; `stopReason` final; teardown do processo do agente — tudo
pelo caminho de produção (`AgentRunner`, com `executor.kind: acp` resolvido por
configuração). Evidência em §4.

Continuam fora de escopo: `authenticate` ACP, `session/cancel`/`session/close`,
`session/load`, elicitation, MCP local e capabilities `fs`/`terminal`. O provedor de
modelo (DeepSeek) é configuração da plataforma, entregue ao processo do agente pelo
wrapper do runtime isolado — o cliente ACP não conhece credencial (§8). Uma dívida
herdada da fase 3 (representação de métricas ausentes no dashboard) segue aberta e está
registrada em §6.

## 2. Runtime verificado

| Item | Valor medido |
|---|---|
| versão executada pelo wrapper | `3.0.65` (`cline --version` pelo wrapper do pipeline) |
| wrapper | `~/automation/bin/cline` (Node do mise + `--data-dir` do pipeline) |
| suporte a ACP no `--help` local | sim: `--acp  Run in Agent Client Protocol (ACP) mode for editor integration` |
| transporte | `stdio`: `stdout` = protocolo, `stderr` = diagnóstico (`[acp] starting ACP mode over stdio…`) |
| `agentInfo` anunciado | `{"name":"cline","version":"3.0.65"}` |
| `agentCapabilities` anunciadas | `loadSession`, `promptCapabilities` (image/audio/embeddedContext) |
| `stopReason` observado no turno real | `end_turn` |

O `--data-dir` do pipeline **não** isolou credencial/estado neste fluxo — fato medido em
§5. Nenhum segredo foi lido, copiado ou versionado: o Symphony continua sem armazenar
credencial do agente.

## 3. Spike e desbloqueio da autenticação

Medido **antes** de qualquer alteração de código, lançando o processo exatamente como o
`acp.command` o lança (com os frames que `ACP.Client` envia, byte a byte, sem adaptador):

- com o runtime ainda sem autenticação utilizável, `initialize` era negociado em
  `protocolVersion: 1`, mas `session/new` respondia
  `{"code":-32000,"message":"Authentication required: Call authenticate before starting a session"}`
  → o cliente já mapeava para `{:acp_auth_required, []}` e a execução real ficava
  bloqueada (a fase 4 permaneceu **pendente** nesse momento);
- a autenticação foi feita **manualmente, fora do Symphony**, pelo dono do ambiente, no
  fluxo do Cline (`cline auth`); nenhuma credencial foi adicionada ao `WORKFLOW.md`, a
  logs ou ao Git;
- depois disso, o mesmo `session/new` passou a devolver um `sessionId` real, e o turno
  real de §4 aconteceu — sem nenhuma alteração de código de produção entre os dois
  estados (a única mudança foi a autenticação do runtime).

## 4. Turno real medido (fase 4)

Reprodução: `cd elixir && make cline-acp-e2e` — dois testes, **2 passed, 0 failures**,
sem *skips* (`SYMPHONY_RUN_CLINE_ACP_E2E=1`), contra o agente real.

Caminho exercitado (sem injeção de executor em teste: a seleção vem de
`executor.kind: acp`):

```
AgentRunner → Executor.Acp → ACP.Client → stdio/JSON-RPC → ~/automation/bin/cline --acp → Cline 3.0.65
```

Comportamento ACP observado no turno real:

| Fase | Observado |
|---|---|
| `initialize` | `protocolVersion: 1`, `agentInfo = {"name":"cline","version":"3.0.65"}` |
| `session/new` | `sessionId` real devolvido (cwd = workspace descartável, `mcpServers: []`) |
| `session/prompt` | enviado com o prompt da issue; resposta final `stopReason = end_turn` |
| `session/update` | `agent_message_chunk` (mensagem do modelo) e `session_info_update` |
| atualização desconhecida | `session_info_update` **não** é método do cliente: tratada como notificação genérica, sem perder o turno |
| frame malformado | nenhum |
| requisição não suportada | nenhuma (`fs/*`, `terminal/*`, elicitation não foram chamados) |
| `session/request_permission` | **nenhuma** requisição de permissão chegou ao Symphony nos turnos medidos (§6) |

Efeito real no workspace descartável, do ponto de vista do Symphony e confirmado pelo
registro de sessão do próprio Cline:

- ferramentas usadas pelo agente: `read_files` → `run_commands` (inspeção) →
  `apply_patch` → `run_commands` (verificação);
- a edição: `answer.sh`, `-echo "1"` → `+echo "42"`;
- o agente executou `bash answer.sh` e confirmou `42` (bytes `34 32 0a`, só o número e o
  *newline*);
- validação determinística do teste: `bash answer.sh` imprime `42`, `answer.sh` difere do
  original e nenhum outro arquivo aparece como alterado no workspace descartável;
- workspace: `/tmp/symphony-cline-acp-turn-*`, com `git init`, removido ao fim do teste;
  nenhum projeto consumidor, clone canônico ou repositório deste projeto foi alvo;
- mensagem final do agente (resumida): *"Updated .../answer.sh so it prints exactly 42"*.

Teardown:

- o processo lançado por `acp.command` é encerrado após `stop_session/1` e o teste
  **assere** que o pid do agente não existe mais (`/proc/<pid>` ausente);
- o Cline, porém, deixa um *hub daemon* destacado (`.cline --cline-hub-daemon`) vivo após
  o fim do turno — comportamento do agente, não do Symphony; registrado em §6.

Provider/modelo efetivamente usados na prova, conforme o registro da própria sessão do
Cline: `provider=openai-codex`, `model=gpt-5.6-terra`. Isso **não** é decisão da
plataforma nem deste fork: é a autenticação que já existia no runtime, usada apenas como
dependência da execução. DeepSeek continua na fase 5 e não foi configurado.

## 5. Autenticação e isolamento do estado (medido)

Três variantes do mesmo handshake + turno curto, para descobrir de onde vem a credencial e
onde o estado é gravado (nada de conteúdo sensível foi lido; só presença/ausência):

| Variante | `initialize` + `session/new` | Onde a sessão foi gravada |
|---|---|---|
| A) wrapper do pipeline (`~/automation/bin/cline --acp`, `--data-dir ~/automation/state/cline`) | ✅ turno completo (`end_turn`) | `~/.cline/data/sessions` (71 → 72) |
| B) binário isolado + `--data-dir /tmp/cline-dd-explicit` | ✅ turno completo (`end_turn`) | `~/.cline/data/sessions` (72 → 73); `/tmp/cline-dd-explicit` = 0 arquivos |
| C) binário isolado + `--config /tmp/…` + `--data-dir /tmp/…` | ❌ `-32000` "Authentication required" | — |

Conclusões medidas (Cline `3.0.65`):

1. a credencial é resolvida pelo **config dir padrão (`~/.cline`)** — mudar `--config`
   derruba a autenticação, mudar `--data-dir` não;
2. o `--data-dir` do pipeline **não** isolou credencial nem estado de sessão neste fluxo:
   `~/automation/state/cline` continua **vazio** e as sessões foram gravadas em
   `~/.cline/data/sessions`;
3. portanto o isolamento hoje é do **runtime** (binário/Node do pipeline via wrapper),
   não da **credencial/estado**: a prova da fase 4 reutilizou a autenticação já existente
   do dono do ambiente, exatamente como dependência de execução.

Consequências registradas:

- o Symphony continua **sem** armazenar credencial do agente e nenhum segredo entrou no
  repositório, no `WORKFLOW.md` do teste, em log ou nesta documentação;
- a promessa de isolamento de credencial/estado do Cline (`agentic-dev-environment`,
  ADR-0005 / `install.sh` / `doctor.sh` / `manifests/tool-versions.txt`) **não** se
  confirma com essa versão do Cline — reconciliação é decisão da plataforma e **não**
  foi feita aqui (este repositório não altera `agentic-dev-environment`).

## 6. Observações, permissões e dívidas

- **Permissões:** nos turnos medidos o Cline **não** enviou
  `session/request_permission` — ele executou suas próprias ferramentas sem consultar o
  cliente ACP. Portanto `acp.auto_approve_requests: true` (configurado apenas no
  `WORKFLOW.md` descartável do teste) não chegou a ser exercitado pelo agente real; o
  caminho de permissão continua validado pelo **agente ACP fake** determinístico, e o
  default global segue *fail-closed* (`false`), intocado.
- **Atualizações desconhecidas:** `session_info_update` chegou como `session/update` e foi
  tratada como notificação genérica; nenhum evento foi perdido e nenhum método não
  suportado foi requisitado.
- **Hub daemon:** o Cline deixa um processo destacado (`--cline-hub-daemon`) vivo após o
  fim do turno — medido em execuções consecutivas, um por execução, com `--cwd` apontando
  para o workspace descartável já removido. O processo do agente lançado por `acp.command`
  é encerrado (asserido pelo teste); o daemon é comportamento do agente e fica registrado
  como observação para a plataforma (limpeza/gestão de daemon) — não é vazamento do
  Symphony.
- **Dívida herdada da fase 3 (Q6), ainda aberta:** com o executor ACP não há métrica de
  uso e o dashboard hoje renderiza ausência como **zeros**; transformar ausência em zero
  é justamente o que Q6 proíbe representar como real. Não foi resolvida nesta PR (escopo:
  integração com o Cline real), e permanece como o próximo item antes de uso com projeto
  consumidor.
- Seguem fora de escopo: cancelamento gracioso (`session/cancel`/`session/close`),
  `session/load`, elicitation, MCP local, capabilities `fs`/`terminal` e `authenticate`
  ACP.

## 7. Verificação reproduzível (opt-in)

`elixir/test/symphony_elixir/cline_acp_e2e_test.exs` segue o padrão de teste externo já
existente no repositório (`@tag skip` por variável de ambiente + alvo próprio no
`Makefile`, como o `make e2e` do upstream):

```bash
cd elixir && make cline-acp-e2e
# ou
SYMPHONY_RUN_CLINE_ACP_E2E=1 mix test test/symphony_elixir/cline_acp_e2e_test.exs
```

| Variável | Papel |
|---|---|
| `SYMPHONY_RUN_CLINE_ACP_E2E=1` | gate: sem ela os dois testes são *skipped* (nunca rodam em `make all`, nunca em CI) |
| `SYMPHONY_CLINE_ACP_COMMAND` | `acp.command` do teste; default = wrapper do pipeline `$HOME/automation/bin/cline --acp` |

Os dois testes: (1) handshake real (`initialize` + `session/new`); (2) turno real pelo
`AgentRunner` em projeto descartável, que só passa se `bash answer.sh` imprimir exatamente
`42`, se nenhum outro arquivo mudar, se os eventos `:session_started`/`:turn_completed`
chegarem e se o processo do agente não existir mais. O agente precisa estar autenticado
fora de banda (o teste nunca autentica em nome do agente nem carrega credencial); sem
autenticação ele falha com mensagem explícita, nunca passa em silêncio.

## 8. Fase 5 — provedor inicial (DeepSeek): mecanismo medido e teste opt-in

A fase 5 liga o **provedor de modelo** ao Cline do caminho ACP acima. A decisão e o
contrato de segredo são da plataforma
(`agentic-dev-environment`: ADR-0003, `config/defaults.env`,
`manifests/tool-versions.txt`, `docs/operations/troubleshooting.md` §19); este
documento registra **o que foi medido no agente real** e como o caminho ACP é provado
com ele, sem duplicar a decisão.

Mecanismo medido no binário `3.0.65` instalado no runtime isolado (bundle do servidor
ACP):

| Item | Medido |
|---|---|
| provedor | `process.env.CLINE_PROVIDER` (senão o provedor restaurado do estado, senão `cline`) |
| modelo | `process.env.CLINE_MODEL` (senão o `defaultModelId` do provedor) |
| credencial | `process.env.CLINE_API_KEY` (senão a credencial restaurada) |
| prontidão da sessão | `isSessionReady` exige `CLINE_API_KEY` **ou** credencial restaurável de uma das `authMethods` anunciadas — `cline`, `cline-pass` e `openai-codex` apenas |
| id do provedor DeepSeek | `deepseek` (família `openai-compatible`, protocolo `openai-chat`, `baseUrl https://api.deepseek.com/v1`) |
| modelos publicados | `deepseek-flash`, `deepseek-v4-pro`, `deepseek-v4-flash` (default do provedor: `deepseek-v4-flash`) |

Consequências para o caminho ACP (todas verificadas em código do binário instalado,
não presumidas):

- `deepseek` **não** está nas `authMethods` do ACP: `cline auth`/`providers.json` não
  deixam a sessão pronta sozinhos, e `session/new` continua respondendo
  `Authentication required` quando não há `CLINE_API_KEY` nem credencial OAuth
  restaurável — o erro que o cliente já mapeia para `{:acp_auth_required, _}`;
- por isso a credencial do provedor é entregue **ao processo do agente** pelo wrapper do
  runtime isolado (`CLINE_API_KEY`), a partir do arquivo de segredos da plataforma: o
  Symphony continua sem conhecer credencial alguma e o caminho ACP não mudou — **nenhuma
  alteração** em `Executor.Acp`/`ACP.Client` foi necessária para a fase 5;
- sem a credencial, o wrapper **não** seleciona provedor/modelo (nenhuma credencial de
  outro provedor — por exemplo a OAuth do estado isolado — é reaproveitada em nome do
  DeepSeek);
- modelo inválido em `CLINE_MODEL` **não** falha: o agente cai no default do provedor.
  O modelo realmente usado precisa ser conferido, não presumido.

### Evidência e teste

`elixir/test/symphony_elixir/cline_deepseek_e2e_test.exs` (opt-in, **pago**, nunca em
`make all`/CI) exige o mesmo turno real do caminho de produção
(`AgentRunner` → `Executor.Acp` → `ACP.Client` → `acp.command`) e acrescenta a prova da
**camada de modelo**:

```bash
cd elixir && make cline-deepseek-e2e
# ou
SYMPHONY_RUN_CLINE_DEEPSEEK_E2E=1 mix test test/symphony_elixir/cline_deepseek_e2e_test.exs
```

| Variável | Papel |
|---|---|
| `SYMPHONY_RUN_CLINE_DEEPSEEK_E2E=1` | gate: sem ela o teste é *skipped* |
| `SYMPHONY_CLINE_ACP_COMMAND` | `acp.command`; default = wrapper do pipeline `$HOME/automation/bin/cline --acp` |
| `SYMPHONY_CLINE_DEEPSEEK_MODEL` | modelo que o turno deve ter usado; default `deepseek-v4-flash` |
| `SYMPHONY_CLINE_STATE_DIR` | estado **isolado** do Cline do pipeline (default `$HOME/automation/state/cline`); nunca `~/.cline` |

`SYMPHONY_CLINE_DEEPSEEK_MODEL` é a **expectativa** do teste; o modelo que o agente
realmente usa vem de `CLINE_MODEL` (default do wrapper, ou o ambiente do operador, que
tem precedência). Ao rodar com outro modelo, informe os dois:
`CLINE_MODEL=deepseek-v4-pro SYMPHONY_CLINE_DEEPSEEK_MODEL=deepseek-v4-pro make cline-deepseek-e2e`.

Além do efeito determinístico no projeto descartável (`bash answer.sh` → exatamente
`42`, nenhum outro arquivo alterado, eventos `:session_started`/`:turn_completed`,
processo do agente encerrado), o teste lê o **registro de sessão que o próprio agente
grava no estado isolado** (`data/sessions/<id>/<id>.json`, sem credencial alguma) e
exige `provider == "deepseek"` e o modelo esperado. Um turno que caísse em outro
provedor — ou sem credencial do provedor — **falha** com mensagem explícita que nomeia
o arquivo de segredos a preencher, em vez de passar como "fase 5 verificada". O teste
também recusa apontar para o estado pessoal e falha se não encontrar o registro da
sessão (na ausência de registro não há evidência de DeepSeek).

Uso/custo do turno (quando existir no registro) é impresso **apenas** como evidência
operacional transitória: não é asserido e não é versionado
(`agentic-dev-environment/docs/architecture/source-of-truth.md`).

### Resultado (prova real executada)

A execução real foi feita com o wrapper do runtime isolado da plataforma
(`acp.command` default) e o segredo real **já configurado sem aspas**:

```bash
cd ~/automation/src/symphony-acp/elixir && make cline-deepseek-e2e
# 1 test, 0 failures
```

O turno percorreu o caminho de produção completo
(`AgentRunner` → `Executor.Acp` → `ACP.Client` → `Cline → DeepSeek`) em projeto
descartável e foi aprovado pelos critérios acima: `bash answer.sh` → exatamente `42`,
apenas `answer.sh` alterado, eventos `:session_started`/`:turn_completed`, processo do
agente encerrado e `provider == "deepseek"` com o modelo esperado lidos no registro de
sessão do próprio agente. **Fase 5 concluída no fork**; a fase 6 do roadmap (teste local
descartável do pipeline inteiro) é o próximo passo da **plataforma**, não deste fork.

A execução real também revelou uma fragilidade **da plataforma** (não deste fork):
`DEEPSEEK_API_KEY="sk-..."` era aceito pelo carregador de ambiente e as aspas viajavam
dentro do valor entregue ao agente, e a API respondia
`Authentication Fails ... api key ... is invalid`. O contrato `KEY=VALUE`, sem aspas,
passou a ser verificado (e nunca "corrigido" em silêncio) na plataforma — sem nenhuma
mudança nesta camada ACP (`agentic-dev-environment`: ADR-0003,
`docs/operations/troubleshooting.md` §19).

## 9. Referências

- [adr/0002](adr/0002-acp-protocol-mapping.md) (mapeamento ACP; Q2/Q5/Q6/Q7),
  [adr/0003](adr/0003-phase3-executor-abstraction-scope.md) e
  [adr/0004](adr/0004-acp-client-implementation.md) (cliente e executor ACP);
- [acp-analysis.md](acp-analysis.md) (análise documental e fontes oficiais do ACP);
- [divergences.md](divergences.md) (registro do diff em relação ao upstream);
- código: `elixir/lib/symphony_elixir/acp/client.ex`,
  `elixir/lib/symphony_elixir/executor/acp.ex`, `elixir/lib/symphony_elixir/agent_runner.ex`;
- testes: `elixir/test/symphony_elixir/cline_acp_e2e_test.exs` (opt-in, agente real),
  `elixir/test/symphony_elixir/cline_deepseek_e2e_test.exs` (opt-in, agente real com o
  provedor DeepSeek — fase 5) e `elixir/test/symphony_elixir/acp_test.exs`
  (determinístico, agente ACP fake);
- plataforma: `agentic-dev-environment/docs/architecture/roadmap.md` (fases 4 e 5),
  `docs/architecture/adr/0002-*`, `docs/architecture/adr/0003-*` (Cline + DeepSeek,
  com o mecanismo do provedor medido), `docs/architecture/adr/0005-*` (isolamento de
  runtime), `docs/operations/troubleshooting.md` (§19, executor sem credencial),
  `manifests/tool-versions.txt` (medições do executor) e
  `docs/security/permissions.md`.
