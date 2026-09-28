# ADR-0003 — escopo da fase 3: abstração implementada, executor fake determinístico

- **Status:** aceito
- **Data:** 2026-09-28
- **Decisores:** arquitetura do fork (rbcorrea26)
- **Relacionado a:** [0001-executor-abstraction.md](0001-executor-abstraction.md),
  [0002-acp-protocol-mapping.md](0002-acp-protocol-mapping.md),
  [../acp-analysis.md](../acp-analysis.md) §2.5, §7 e §9,
  [../divergences.md](../divergences.md), `SPEC.md` §5.3 e §6.3

## Contexto

O [ADR-0001](0001-executor-abstraction.md) decidiu a forma da abstração e a ordem
planejada da fase 3; o [ADR-0002](0002-acp-protocol-mapping.md) decidiu o mapeamento
de protocolo. A implementação do **primeiro incremento** da fase 3 (abstração +
seleção por configuração + executor fake) revelou três pontos que precisam ficar
registrados, porque um deles difere da previsão de impacto do ADR-0001:

1. **O fake planejado e o fake implementado não são o mesmo objeto.** O ADR-0001
   (passo 3) e [../acp-analysis.md](../acp-analysis.md) §2.5 descrevem o validador
   da fase 3 como um **agente ACP falso por stdio** — um processo que fala JSON-RPC
   por linha, no padrão do `fake-codex`. Esse fake só tem o que exercitar quando
   existir o cliente ACP real (`SymphonyElixir.Executor.Acp`), que **não** faz parte
   deste incremento. Manter o agente falso por stdio sem cliente ACP significaria
   implementar o parser/transporte ACP fora do escopo decidido.
2. **A superfície upstream é maior que a prevista.** O ADR-0001 §Impacto esperado
   previa **dois** arquivos upstream alterados (`agent_runner.ex` e
   `config/schema.ex`). O erro de preflight decidido na §Decisão item 3
   (`{:unsupported_executor_kind, kind}`, "como `{:unsupported_tracker_kind, kind}`")
   vive em `config.ex` (`validate_settings/1`) e precisa de um ramo próprio no
   `orchestrator.ex`, senão o operador lê "Failed to fetch from issue tracker" para
   um erro de executor. São **quatro** arquivos upstream.
3. **`acp.*` não tem o que configurar nesta fase.** Sem cliente ACP não existe
   comando, capability, autenticação nem timeout específicos de ACP. Criar o bloco
   agora seria inventar chave sem comportamento por trás.

O que **não** mudou: a decisão do ADR-0001 (behaviour `SymphonyElixir.Executor`,
`Executor.Codex` como delegação pura, `executor.kind` com default `codex`,
`codex.*` intacto, nenhuma migração de timeout, nenhuma reescrita de
`codex/app_server.ex`) e a decisão do ADR-0002 (mapeamento de protocolo) — este ADR
não a substitui nem a reinterpreta; ele registra o recorte do incremento e as
divergências de superfície.

## Decisão

### 3.1 O executor fake é uma implementação do behaviour, só de teste

- `SymphonyElixir.Executor.Fake` é definido **dentro da suíte de testes**
  (`elixir/test/symphony_elixir/executor_fake_test.exs`), implementa
  `@behaviour SymphonyElixir.Executor` e **não** é registrado no mapa de
  `SymphonyElixir.Executor`.
- Consequência deliberada: nenhum `WORKFLOW.md` consegue selecioná-lo
  (`executor.kind` só resolve `codex`); não existe caminho de produção que aceite
  um executor falso que "sempre conclui". Não há sandbox nem credencial envolvidos.
- O `AgentRunner` aceita `opts[:executor]` (módulo) para os testes injetarem a
  implementação, no mesmo espírito dos seams já existentes
  (`opts[:max_turns]`, `opts[:issue_state_fetcher]`, `opts[:worker_host]`). Produção
  continua resolvendo pelo `executor.kind`.
- O **agente ACP falso por stdio** permanece planejado como validador de
  `SymphonyElixir.Executor.Acp`: ele entra junto com o cliente ACP real, que é a
  próxima fase e exige [ADR-0002](0002-acp-protocol-mapping.md).

### 3.2 Preflight valida o kind do executor

- `SymphonyElixir.Executor.validate_config/1` é chamado por
  `SymphonyElixir.Config.validate_settings/1`, na mesma posição em que o tracker já
  é validado: `Config.validate!()` passa a devolver
  `{:error, {:unsupported_executor_kind, kind}}` e a configuração inválida bloqueia
  dispatch (mantendo a última configuração boa, como no tracker).
- `SymphonyElixir.Orchestrator` ganha um ramo de log próprio para esse erro.
- `Executor.module!/0` permanece simples (padrão `Tracker.adapter/0`): com preflight
  validando o kind, ele só resolve configuração já validada.

### 3.3 Resolução do módulo: uma vez por tentativa, não por chamada

O runner resolve o módulo **uma vez por tentativa de worker** e passa
`%{executor: modulo, session: session}` (mapa interno, privado) para o ciclo de
turnos. Motivos:

- preserva o limite de aridade do gate `credo --strict` (máximo 8 parâmetros);
- evita trocar de executor no meio de uma sessão se `executor.kind` mudar por
  reload dinâmico do `WORKFLOW.md` — `stop_session/1` no `after` sempre fecha a
  sessão no **mesmo** módulo que a abriu;
- a sessão continua opaca para o runner: o mapa só carrega o módulo e o termo
  opaco, nenhuma estrutura de protocolo.

### 3.4 O que o fake simula (vocabulário do ADR-0002)

Sem cliente ACP, o fake simula o que o orquestrador realmente consome: eventos no
formato `%{event: atom, timestamp: DateTime, session_id: String.t(), payload: map()}`
com `session_id` composto `<sessão>-<turno>`, `:session_started` por turno
(preservando `turn_count` e dashboard), `:notification` para conteúdo, e
`:turn_completed` / `:turn_failed` / `{:error, {:turn_cancelled, ...}}` como
desfechos — exatamente o mapeamento de [ADR-0002](0002-acp-protocol-mapping.md)
§2.3–§2.4. Ele é controlado por arquivos dentro do workspace recebido
(`fake-executor.plan` lido, `fake-executor.trace` escrito), é determinístico e não
usa rede, processo externo, modelo nem credencial.

### 3.5 Configuração e documentação upstream

- Entra **apenas** `executor.kind` (default `codex`). Nenhuma chave de `codex.*` é
  renomeada, movida ou removida; nenhum timeout migra para `executor.*` (Q1);
  nenhum bloco `acp.*` é criado nesta fase (item 3 do Contexto).
- `SPEC.md` e `elixir/WORKFLOW.md` **não** mudam: nenhum comportamento documentado
  pelo upstream muda. `SPEC.md` §5.3 permite explicitamente chaves de topo
  adicionais por extensão e o default `codex` mantém o exemplo do `WORKFLOW.md`
  correto; a chave nova é documentada onde o upstream documenta configuração de
  implementação (`elixir/README.md` §Configuration), conforme a política de docs de
  `elixir/AGENTS.md`.
- O harness de teste ganha apenas `executor_kind` opcional em
  `test/support/test_support.exs` (aditivo; `nil` não emite o bloco, que é o caso
  dos workflows atuais).



## Consequências

- **Positivas:** o ciclo do `AgentRunner` passa a ser comprovadamente executável por
  uma implementação de executor diferente, sem Cline, sem modelo e sem credencial;
  o caminho Codex continua sendo o mesmo código, com uma chamada de indireção a
  mais; a escolha de executor é configuração com erro de preflight explícito.
- **Negativas / custos:** o incremento **não** prova o protocolo ACP — prova a
  abstração; o fake desta fase não substitui o agente ACP falso previsto para a fase
  do cliente ACP; o diff upstream é maior que a previsão do ADR-0001 (quatro
  arquivos + o harness de teste), registrado em
  [../divergences.md](../divergences.md).
- **Obrigações:** o fake nunca pode ser registrado como executor selecionável;
  quando `Executor.Acp` entrar, ele precisa do agente falso por stdio do
  [ADR-0002](0002-acp-protocol-mapping.md) e da validação de capability mínima (Q3);
  dívidas herdadas (nomes `codex_*`, reuso de chaves `codex.*`, métricas ausentes)
  continuam como estão em [0001](0001-executor-abstraction.md) §Dívidas.

## Alternativas descartadas

| Alternativa | Por que foi descartada |
|---|---|
| registrar o fake em `executor.kind` (`"fake"`) | torna um executor que sempre "conclui" selecionável em produção — falha silenciosa e promessa falsa de execução |
| validar o kind apenas em `Executor.module!/0` (sem preflight) | contraria a decisão do ADR-0001 item 3 e faz a falha aparecer só na tentativa do worker, com erro genérico |
| criar `acp.*` neste incremento | chave sem comportamento por trás; inventa configuração que o ADR-0002 só justifica quando existir cliente ACP |
| implementar o agente ACP falso por stdio agora, junto com um cliente ACP mínimo | amplia o escopo para o cliente ACP real (rede, autenticação, capabilities, cancelamento) sem fase própria nem decisão humana |
| fake em `test/support/*.exs` com `test_helper.exs`/`mix.exs` alterados | dois arquivos upstream extras para um dublê de teste cujo único consumidor é um arquivo de teste; módulo definido no arquivo de teste não entra no relatório de cobertura e não muda o harness |
| resolver o módulo a cada chamada (como `Tracker.adapter/0`) | permitiria trocar de executor entre turnos da mesma sessão em caso de reload, e `stop_session/1` poderia fechar a sessão no módulo errado |
| manter `Executor.Codex` sem `@impl`/behaviour | perde `@impl`, checagem de forma e dialyzer; o behaviour já está decidido no ADR-0001 |

## Implementação

Estado: **implementado neste incremento** (abstração + seleção + delegado Codex +
executor fake de teste). **Não** implementado aqui: cliente ACP real, Cline,
DeepSeek, MCP, capabilities `fs`/`terminal`, sandbox ACP, autenticação ACP,
ferramentas de tracker via ACP, token accounting real de ACP e cancelamento
gracioso de protocolo.

| Arquivo | Tipo | Mudança |
|---|---|---|
| `elixir/lib/symphony_elixir/executor.ex` | novo | behaviour (`@callback` × 3) + `for_kind/1`, `module!/0`, `validate_config/1` |
| `elixir/lib/symphony_elixir/executor/codex.ex` | novo | delegação pura para `SymphonyElixir.Codex.AppServer` |
| `elixir/lib/symphony_elixir/agent_runner.ex` | upstream alterado | as três chamadas passam pelo executor selecionado; texto do prompt de continuação neutralizado (Q9); `opts[:executor]` para testes |
| `elixir/lib/symphony_elixir/config/schema.ex` | upstream alterado (aditivo) | bloco `executor` com `kind` (default `"codex"`) |
| `elixir/lib/symphony_elixir/config.ex` | upstream alterado | preflight do `executor.kind` |
| `elixir/lib/symphony_elixir/orchestrator.ex` | upstream alterado | ramo de log do erro de executor |
| `elixir/README.md` | upstream alterado | documenta `executor.kind` |
| `elixir/test/support/test_support.exs` | upstream alterado (aditivo) | `executor_kind` opcional no harness |
| `elixir/test/symphony_elixir/executor_test.exs` | novo | seleção, preflight, paridade da delegação Codex |
| `elixir/test/symphony_elixir/executor_fake_test.exs` | novo | executor fake determinístico + ciclo do runner pela abstração |

### O que continua igual no upstream

- `SymphonyElixir.Codex.AppServer` **não foi alterado** em nenhuma linha: mesmos
  argumentos, mesmos retornos, mesma sessão; `Executor.Codex` apenas repassa.
- `codex.command`, `codex.approval_policy`, `codex.thread_sandbox`,
  `codex.turn_sandbox_policy`, `codex.turn_timeout_ms`, `codex.read_timeout_ms` e
  `codex.stall_timeout_ms` seguem exatamente como estavam, com os mesmos defaults e
  validações; nenhum workflow existente precisa ser editado.
- Política de turnos, continuação, retry/backoff, stall, workspace, hooks,
  reconciliação e bloqueio por `:turn_input_required`/`:approval_required`
  continuam no `AgentRunner`/`Orchestrator`, sem duplicação.
- Eventos, nomes `codex_*` de estado/telemetria/dashboard e o payload do dashboard
  permanecem como no upstream (Q8).
- Testes existentes não foram alterados; a cobertura continua 100% sem nova entrada
  em `ignore_modules`.

### Dívidas registradas por este incremento

- o fake não fala ACP: o agente ACP falso por stdio
  ([../acp-analysis.md](../acp-analysis.md) §2.5) continua pendente para a fase do
  cliente ACP;
- `opts[:executor]` existe para teste e não é configuração de workflow; se algum dia
  houver seleção dinâmica de executor em produção, ela precisa de ADR próprio;
- o runner resolve o módulo por tentativa, mas um reload de `executor.kind` entre
  **tentativas** continua trocando o executor do próximo worker — comportamento
  desejado, mas não exercitado por teste nesta fase porque só existe um kind;
- a fase 3 do roadmap da plataforma
  (`agentic-dev-environment/docs/architecture/roadmap.md`) entrega, neste
  incremento, a abstração provada por fake; a atualização de status da plataforma
  (estágio 4 de `pipeline.md`) depende de decisão humana e de PR no repositório da
  plataforma, porque o caminho ACP real ainda não existe.
