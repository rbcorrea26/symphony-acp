# ADR-0001 — abstração de executor (menor mudança para adicionar ACP)

- **Status:** aceito (implementado na fase 3: abstração no incremento 1 —
  [0003](0003-phase3-executor-abstraction-scope.md) — e caminho ACP no incremento 2 —
  [0004](0004-acp-client-implementation.md))
- **Data:** 2026-09-27 — decisões humanas Q1–Q10 incorporadas nesta revisão
- **Decisores:** arquitetura do fork (rbcorrea26)
- **Relacionado a:** [0002-acp-protocol-mapping.md](0002-acp-protocol-mapping.md),
  [../acp-analysis.md](../acp-analysis.md) §10 (decisões Q1–Q10),
  [../divergences.md](../divergences.md), `SPEC.md` §10.7, e (plataforma)
  `agentic-dev-environment/docs/architecture/adr/0002-acp-como-contrato-de-executor.md`

## Contexto

O fork `rbcorrea26/symphony-acp` existe para adicionar um caminho de executor
ACP ao Symphony preservando integralmente o caminho Codex app-server. A
plataforma já aprovou a decisão ("ACP como contrato de executor") no
`agentic-dev-environment`; o **como** é responsabilidade deste repositório.

O estado verificado do código (análise completa em
[../acp-analysis.md](../acp-analysis.md) §2) é:

- `SymphonyElixir.AgentRunner` é o dono da tentativa de trabalho por issue
  (workspace, hooks, ciclo de turnos, limite `agent.max_turns`, continuação por
  estado do issue no tracker) e usa o executor por **três chamadas**:
  `AppServer.start_session/2` (linha 92), `AppServer.stop_session/1` (96) e
  `AppServer.run_turn/4` (105);
- o termo de sessão é tratado como **opaco** pelo runner (o único campo lido é
  `turn_session[:session_id]`, e apenas para log);
- `SymphonyElixir.Codex.AppServer` é o cliente JSON-RPC sobre stdio, com
  aprovações, ferramentas dinâmicas, sandbox e timeouts embutidos;
- o **orquestrador não conhece o executor**: ele consome eventos
  (`{:codex_worker_update, issue_id, message}`) via
  `Orchestrator.integrate_codex_update/2`, decide bloqueio por
  `:turn_input_required`/`:approval_required`, mede stall por
  `codex.stall_timeout_ms`, aplica retry com backoff e extrai tokens de campos
  específicos de Codex (degradando para zero quando ausentes);
- não existe hoje nenhuma noção de "selecionar executor" na configuração: o
  bloco `codex.*` é nomeado pelo fornecedor e o preflight exige
  `codex.command` não vazio (`SPEC.md` §6.3).

Já existe no repositório um precedente de indireção por configuração: o
`SymphonyElixir.Tracker` mantém um mapa `kind -> módulo` (`@adapters` em
`tracker.ex` linhas 13–20), um `@callback` para o contrato de leitura
(22–27) e `adapter_for_kind/1` (93–99). A abstração de executor deve seguir o
mesmo padrão, por consistência e por ser o menor caminho.

### Restrições que a decisão precisa respeitar

1. diff mínimo contra upstream, sem refatoração oportunista;
2. Codex app-server continua suportado e não pode regredir;
3. ACP é extensão, nunca substituição;
4. nenhuma decisão de plataforma (executor inicial, modelo, gates) é tomada aqui;
5. toda alteração em arquivo upstream entra em
   [../divergences.md](../divergences.md);
6. a implementação só começa com este ADR integrado em `main` e com o
   **executor ACP falso determinístico** como primeiro alvo (Q10);
7. nenhuma migração oportunista de `codex.*`: chaves existentes não são
   renomeadas, movidas nem removidas nesta fase (Q1).

## Decisão

Decidimos que o Symphony acessa o executor por **uma indireção interna com
behaviour**, chamada `SymphonyElixir.Executor`, com uma implementação por
protocolo:

```
AgentRunner ──▶ SymphonyElixir.Executor (behaviour + seleção por configuração)
                 ├── SymphonyElixir.Executor.Codex ──▶ SymphonyElixir.Codex.AppServer (intacto)
                 └── SymphonyElixir.Executor.Acp    ──▶ cliente ACP por stdio (novo)
```

A superfície do behaviour é **exatamente** o que o runner usa hoje — nada mais:

```elixir
@callback start_session(workspace :: Path.t(), opts :: keyword()) ::
            {:ok, term()} | {:error, term()}

@callback run_turn(session :: term(), prompt :: String.t(), issue :: term(), opts :: keyword()) ::
            {:ok, map()} | {:error, term()}

@callback stop_session(session :: term()) :: :ok
```

Pontos da decisão:

1. `Executor.Codex` é **delegação pura** para `Codex.AppServer` (mesmas três
   funções), com o `session` do Codex repassado como termo opaco. O arquivo
   upstream `codex/app_server.ex` **não é alterado**.
2. `Executor.Acp` implementa o protocolo ACP do lado cliente (Symphony é o
   *client* ACP; Cline/qualquer agente é o *agent*), com o mapeamento definido em
   [ADR-0002](0002-acp-protocol-mapping.md).
3. A seleção é por configuração (`executor.kind`, default `codex`), no mesmo
   espírito de `tracker.kind`; kind desconhecido é erro de preflight
   (`{:unsupported_executor_kind, kind}`), como
   `{:unsupported_tracker_kind, kind}`.
4. O `session` continua sendo um termo opaco: nenhuma estrutura de protocolo
   atravessa a fronteira do behaviour.
5. A política de turnos, continuação, retry, stall, workspace e hooks **não**
   muda e **não** é duplicada: continua em `AgentRunner`/`Orchestrator`.
6. Capacidades de cliente (Q3): na fase 3 anuncia-se o **mínimo necessário** —
   nada de `fs` e nada de `terminal`. Capacidade não anunciada é tratada como
   *unsupported*; ampliar capacidades só em fase posterior, com necessidade e
   teste concretos.

### Decisões humanas incorporadas (Q1–Q10)

As questões abertas da análise foram decididas pelo humano em 2026-09-27
(detalhe em [../acp-analysis.md](../acp-analysis.md) §10). As que governam esta
abstração:

| # | Decisão | Efeito concreto nesta fase |
|---|---|---|
| Q1 | Configuração: `executor.kind` com default `codex`; `codex.*` preservado **sem breaking change**; bloco `acp.*` apenas para configuração específica do executor ACP; timeouts genéricos **não** migram agora para `executor.*` | o schema ganha seletor, não renomeação; qualquer valor de `codex.*` reutilizado temporariamente pelo caminho ACP fica registrado como **dívida de compatibilidade/nomeação** (§Dívidas) |
| Q3 | Capabilities: mínimo necessário; sem `fs`; sem `terminal` | cliente ACP anuncia quase nada; nada de canal alternativo de escrita/execução |
| Q8 | Nomes internos `codex_*` (estado/telemetria/dashboard) mantidos inicialmente | zero refactor de nomes; dívida registrada (§Dívidas) |
| Q9 | Texto hardcoded que mencione "Codex" deve ser neutralizado **quando a abstração entrar** | muda na fase 3, em `agent_runner.ex`, junto com as 3 chamadas; **não** muda nesta PR documental |
| Q10 | Executor inicial: **fake ACP determinístico** na fase 3; Cline real só na fase 4; DeepSeek depois | a abstração precisa ser provada sem Cline, sem modelo e sem credencial |

Q2, Q4, Q5, Q6 e Q7 são de protocolo/comportamento ACP e estão registradas em
[ADR-0002](0002-acp-protocol-mapping.md) §2.2, §2.5, §2.6, §2.7 e §2.8.

### Dívidas explicitamente registradas (não são desenho ideal)

| Dívida | Origem | Quando resolver |
|---|---|---|
| Reuso temporário de chaves `codex.*` (timeouts/stall) pelo caminho ACP | Q1 (não migrar agora) | junto com a consolidação de configuração por executor, em mudança própria com aliases de compatibilidade |
| Nomes internos `codex_*` em estado, telemetria e payload do dashboard | Q8 (não refatorar agora) | quando houver mais de um executor em uso real |
| `codex.command` como única noção de comando | Q1 | resolvido na fase 3 com o comando específico do executor ACP (`acp.*`) |

### Por que é a menor mudança

| Medida | Opção A (escolhida) | Opção B (esconder ACP no cliente Codex) | Opção C (runner paralelo) | Opção D3 (shim externo) |
|---|---|---|---|---|
| Arquivos upstream alterados | 2 (`agent_runner.ex` ~3 linhas; `config/schema.ex` aditivo) | 1 arquivo grande reescrito (`codex/app_server.ex`) | 2+ (`agent_runner.ex`, `orchestrator.ex`) | 0 (ou `WORKFLOW.md`) |
| Arquivos novos | 3 (`executor.ex`, `executor/codex.ex`, `executor/acp.ex`) | 0–1 | 2+ | 1 binário **fora** do repositório |
| Risco de regressão Codex | baixo (delegação) | alto (mesmo módulo) | médio (dois runners) | baixo no Elixir, alto no protocolo |
| Duplicação de política | nenhuma | nenhuma | total (`max_turns`, continuação, hooks) | nenhuma, mas protocolo Codex reimplementado |
| Testável no fork | sim (agente ACP falso por stdio) | difícil (mistura) | sim, mas dobrado | não (código fora do fork) |
| Sincronização com upstream | conflito trivial em 2 arquivos | conflito permanente | conflito em 2 arquivos | nenhum conflito, mas dívida invisível |

A escolha é a menor mudança que **não** reescreve arquivo upstream de execução e
**não** duplica política: 3 arquivos novos e ~3 linhas alteradas em um arquivo.

### Como o Codex continua funcionando

- `Executor.Codex.start_session/2` chama `AppServer.start_session/2`;
  `run_turn/4` chama `AppServer.run_turn/4`; `stop_session/1` chama
  `AppServer.stop_session/1` — mesmos argumentos, mesmo retorno, mesma sessão.
- `codex.command`, `codex.approval_policy`, `codex.thread_sandbox`,
  `codex.turn_sandbox_policy`, timeouts e stall permanecem exatamente como estão.
- `WORKFLOW.md` existentes continuam válidos: `executor` ausente ⇒
  `kind: codex`.
- Nenhum workflow existente precisa ser editado: `codex.*` continua sendo o
  bloco que define o executor Codex e `executor.kind` é **opcional** com default
  `codex` (Q1). Não há migração, renomeação nem remoção de chave.
- Nenhum teste existente precisa mudar: os testes de `AppServer` chamam o módulo
  diretamente (`app_server_test.exs`, `core_test.exs`) e continuam válidos.
- O comportamento observável (eventos, logs, dashboard, retry, bloqueio) é
  idêntico no caminho Codex, porque o caminho de código é o mesmo com uma
  chamada de função a mais.


### Impacto esperado em arquivos (planejado na decisão; implementado na fase 3)

| Arquivo | Tipo | Mudança esperada |
|---|---|---|
| `elixir/lib/symphony_elixir/executor.ex` | novo | behaviour (`@callback` × 3) + seleção por configuração (`for_kind/1`, `module!/0`) + `@spec` em todo `def` |
| `elixir/lib/symphony_elixir/executor/codex.ex` | novo | delegação pura para `Codex.AppServer` |
| `elixir/lib/symphony_elixir/executor/acp.ex` | novo | cliente ACP por stdio (handshake, `session/new`, `session/prompt`, stream `session/update`, permissão, timeouts), conforme [ADR-0002](0002-acp-protocol-mapping.md) |
| `elixir/lib/symphony_elixir/agent_runner.ex` | **upstream alterado** | trocar `alias SymphonyElixir.Codex.AppServer` por `SymphonyElixir.Executor` e as 3 chamadas; neutralizar texto hardcoded que mencione "Codex" (Q9); nenhuma alteração de política |
| `elixir/lib/symphony_elixir/config/schema.ex` | **upstream alterado (aditivo)** | `executor.kind` (default `"codex"`) e bloco `acp.*` para configuração específica do ACP; validação de kind suportado; **nenhum** campo de `codex.*` removido, renomeado ou movido (Q1) |
| `elixir/WORKFLOW.md` | upstream | **não** precisa mudar: o default `codex` mantém o exemplo válido; só muda se o exemplo ficar incorreto |
| `elixir/README.md` | upstream | obrigatório quando a chave existir (política de docs do upstream): documentar `executor.kind`/`acp.*` e o que o ACP **não** garante |
| `docs/fork/divergences.md` | fork | registrar cada arquivo upstream alterado, com motivo |
| `elixir/lib/mix/tasks/specs.check.ex` | **não** alterado | continua cobrindo `@spec` de todo `def` público |

Na implementação o plano foi cumprido com uma divisão a mais: o cliente ACP ficou em
`elixir/lib/symphony_elixir/acp/client.ex` e o executor em
`elixir/lib/symphony_elixir/executor/acp.ex` ([0004](0004-acp-client-implementation.md)).

### Impacto esperado em testes

- **Existentes:** nenhum teste precisa mudar; `app_server_test.exs` continua
  exercitando o cliente Codex diretamente e `workspace_and_config_test.exs`
  continua validando defaults (a chave `executor` é aditiva).
- **Novos (fase 3):** agente ACP **falso** executável que fala JSON-RPC por linha
  (mesmo padrão do `fake-codex` já usado nos testes), cobrindo: handshake,
  `session/new`, turno com `session/update` + `stopReason: end_turn`, silêncio
  (timeout), morte do processo, linha não-JSON, `session/request_permission`
  (auto-aprovar e não aprovar), `stopReason: cancelled` e `session/prompt`
  terminando com `refusal`/`max_tokens`.
- **Cobertura:** `mix.exs` exige threshold 100 e hoje ignora explicitamente
  `Codex.AppServer`, `AgentRunner` etc. Preferência declarada: **testar** o
  caminho ACP com o agente falso; se algum trecho for inviável de cobrir sem
  fabricar teste, a entrada correspondente em `ignore_modules` precisa ser
  justificada no PR (e registrada como divergência, por ser arquivo upstream).
- **Gates:** `make -C elixir all` (`fmt-check`, `lint` = `specs.check` + `credo
  --strict`, `coverage`, `dialyzer`) e `mix specs.check` valem para os módulos
  novos.
- **Flake pré-existente (não é desta mudança):** `core_test.exs:1062`
  ("abnormal worker exit increments retry attempt progressively") falha
  ocasionalmente por timing sob carga do suite com cobertura, passa isolado e em
  rerun. Registrado em
  [issue #2](https://github.com/rbcorrea26/symphony-acp/issues/2); a correção
  entra em PR próprio, sem enfraquecer a asserção.

### Compatibilidade upstream

- `SPEC.md` continua autoritativo: o fork adiciona um campo de configuração e
  uma indireção de código; **não** contradiz o spec (implementação pode ser
  superset — `elixir/AGENTS.md`).
- O spec passa a exigir atualização **somente** se a fase 3 mudar comportamento
  documentado (por exemplo, preflight que passa a validar o comando do executor
  selecionado). Nesse caso, a atualização do `SPEC.md` entra no mesmo PR, como
  manda `elixir/AGENTS.md`.
- Sincronização futura com `upstream/main` deve conflitar, no máximo, em
  `agent_runner.ex` (3 linhas) e `config/schema.ex` (bloco novo). Ambos são
  resolvíveis preservando o comportamento upstream.


## Consequências

- **Positivas:** ACP entra sem tocar no cliente Codex; o comportamento upstream é
  preservado por construção; a escolha de executor vira configuração; o
  precedente do `Tracker` é reutilizado (uma forma de indireção só no
  repositório); a fase 3 pode ser validada com um agente ACP falso, sem Cline e
  sem credencial de modelo.
- **Negativas / custos:** uma indireção a mais no caminho de execução; o caminho
  ACP tem **menos garantias** que o Codex (ver
  [../acp-analysis.md](../acp-analysis.md) §8) e isso precisa ficar visível na
  documentação de configuração; os nomes `codex.*`/`codex_*` passam a governar
  execução ACP (dívida registrada, Q1/D20/D29); a superfície de teste cresce.
- **Obrigações:** todo arquivo upstream alterado registrado em
  [../divergences.md](../divergences.md) no mesmo PR; `mix specs.check` e
  `make -C elixir all` verdes; nada de credencial, modelo ou regra de negócio
  dentro da abstração; cancelamento gracioso, MCP local, elicitation e modos
  ficam fora da fase 3 (exigem ADR próprio); as dívidas da tabela acima ficam
  registradas aqui e **não** podem virar decisão silenciosa na implementação.

## Alternativas descartadas

| Alternativa | Por que foi descartada |
|---|---|
| ACP escondido atrás da interface atual do Codex (reescrever `Codex.AppServer`) | reescreve o arquivo upstream mais volátil do caminho de execução; risco alto de regressão no Codex; obriga a espremer semântica ACP em forma Codex; conflito permanente na sincronização |
| `AgentRunner` paralelo para ACP | duplica política de turnos/continuação/hooks/worker host; dois donos da mesma regra; orquestrador precisaria de um ramo novo no dispatch; dobra a superfície de teste |
| Shim externo (comando configurado apontando para um tradutor ACP ↔ Codex app-server) | menor diff no Elixir, mas exige reimplementar o protocolo Codex app-server **fora** do repositório (approvals, dynamic tools, token usage), sem teste no fork; esconde o mapeamento ACP do lugar onde precisa ser auditável; não permite usar recursos sem forma Codex (`session/request_permission` com opções, `session/cancel`) |
| Processo dedicado por sessão (`GenServer`/`DynamicSupervisor` de executor) | adiciona supervisão e ciclo de vida sem necessidade: a Task do worker já é a dona do `try/after` da sessão |
| Indireção por módulo sem behaviour (só mapa `kind -> módulo`, como `Tracker` sem `@callback`) | é aceitável e ainda menor, mas perde `@impl`, checagem de forma e dialyzer; o custo do behaviour é uma dúzia de linhas — adotada como **forma** da Opção A, não como alternativa |
| Deixar a escolha de executor fora da configuração (flag de ambiente) | configuração de workflow pertence ao `WORKFLOW.md` (`SPEC.md` §5–6) e precisa sobreviver ao reload dinâmico; ambiente não é contrato versionado |
| Implementar ACP direto no `Orchestrator` | coloca protocolo no control plane, exatamente o acoplamento que a abstração existe para evitar |

## Implementação

Estado: **implementado** (fase 3 concluída). A ordem planejada abaixo foi seguida item
a item: a abstração de executor e `executor.kind` entraram no incremento 1
([0003](0003-phase3-executor-abstraction-scope.md)) e o caminho ACP
(`SymphonyElixir.ACP.Client` + `SymphonyElixir.Executor.Acp`, validado pelo agente ACP
fake determinístico) no incremento 2 ([0004](0004-acp-client-implementation.md)); o
caminho Codex segue intacto e como default. O **Cline real como agente ACP** foi
executado depois, na fase 4 ([../cline-acp-integration.md](../cline-acp-integration.md)).
As decisões humanas Q1–Q10 estão registradas (§Decisões humanas incorporadas e
[ADR-0002](0002-acp-protocol-mapping.md)).

Ordem seguida na fase 3 (plataforma: "runner ACP com fake"):

1. integrar este ADR em `main` (a implementação parte da `main` integrada, não
   desta branch);
2. criar `SymphonyElixir.Executor` (behaviour + seleção) e
   `SymphonyElixir.Executor.Codex` (delegação), trocar as 3 chamadas em
   `agent_runner.ex` e neutralizar o texto hardcoded que menciona "Codex" (Q9),
   com testes provando paridade do caminho Codex e **nenhum** workflow existente
   invalidado;
3. criar `SymphonyElixir.Executor.Acp` implementando
   [ADR-0002](0002-acp-protocol-mapping.md), validado por um **agente ACP falso
   determinístico** (Q10) — sem Cline, sem modelo, sem credencial;
4. adicionar `executor.kind` (default `"codex"`) e o bloco `acp.*` ao schema,
   preservando defaults e reload, com teste de workflow antigo (sem `executor`)
   continuando válido e sem migrar nenhuma chave de `codex.*` (Q1);
5. registrar as divergências e atualizar `elixir/README.md` no que mudou de fato.

Coerência com o roadmap da plataforma (`agentic-dev-environment/docs/architecture/roadmap.md`):
fase 3 = runner ACP com fake (este ADR + [ADR-0002](0002-acp-protocol-mapping.md));
fase 4 = Cline como **agente** ACP real; fase 5 = DeepSeek. **Cline não entra na
fase 3** e nada nesta PR depende dele. A fase 4 foi executada depois, sem alterar esta
decisão: estado medido e ressalvas em
[../cline-acp-integration.md](../cline-acp-integration.md).

Entradas para a fase 4 (não decididas aqui e **não** implementadas por ela): MCP local
para ferramentas do tracker, cancelamento gracioso, `session/load`, elicitation,
modos/config options e representação de métricas ausentes (dívida Q6 registrada em
[ADR-0002](0002-acp-protocol-mapping.md) §2.8) — todas seguem abertas.
