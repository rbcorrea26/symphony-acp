# ADR-0005 (fork) — estágio de entrega: gates, Draft PR, CI, candidato e handoff

- **Status:** aceito (implementado; validado em execução real contra um repositório
  descartável)
- **Data:** 2026-09-29
- **Decisores:** arquitetura do fork / plataforma (rbcorrea26)
- **Relacionado a:** `agentic-dev-environment` ADR-0006 (gates e revisão),
  [../README.md](../README.md) (carta do fork), [0002](0002-acp-protocol-mapping.md)

## Contexto

Até a fase 5 o fork executava turnos de agente e terminava: nenhum estágio depois do
executor existia no Symphony (issue ainda em estado ativo → o runner continuaria os
turnos). A plataforma aprovou gates determinísticos, Draft PR, CI, *candidate stable*
e `ready-for-human` como estágios do fluxo, mas o dono deles é o **control plane**
(ver a fronteira em `agentic-dev-environment/docs/architecture/pipeline.md` §2).

Sem eles, "pronto" dependeria da autoavaliação do agente e a publicação teria de ser
feita por fora do pipeline — exatamente o que a fase 6 precisa provar que **não**
acontece.

## Decisão

O fork passa a ter um estágio de **entrega** (`SymphonyElixir.Delivery`), executado
pelo `AgentRunner` **depois** dos turnos e **só** quando o workflow do consumidor
opta (`delivery.enabled: true`). Sem o bloco, o comportamento upstream é preservado.

Regras da decisão:

1. **os gates são do consumidor** (`delivery.gates`, comando versionado no projeto);
   exit != 0 = execução falha, sem publicar nada. O fork nunca contém gate de
   projeto;
2. a **única escrita** em direção ao repositório do consumidor é uma branch
   (`delivery.branch_prefix` + identificador da issue) e um **Draft** PR sobre
   `delivery.base_branch`; nunca push na base, nunca force push, nunca merge;
3. **candidate stable é derivado, nunca inventado**: é o SHA head da branch cujos
   gates locais passaram, cujos check runs do CI concluíram com sucesso e que era o
   head da branch ao fim da observação. Um push que chega durante a observação
   **invalida** o candidato e a observação recomeça no novo SHA;
4. **o estado vem do GitHub** (PR aberto da branch, ref, check runs, labels,
   comentários): é isso que torna retry e reconciliação idempotentes — a segunda
   execução sobre o mesmo candidato não cria segunda branch, segunda PR, segundo
   comentário nem repete o push;
5. **a review é one-shot** e acontece depois do candidato estável. Um candidato
   reconciliado (nada novo publicado) **não** dispara nova solicitação, para não
   criar loop. Indisponibilidade é registrada e **nunca** bloqueia o handoff;
6. o **handoff** aplica o rótulo `delivery.handoff_label`, remove os rótulos de
   entrada do tracker (`tracker.required_labels`, quando
   `delivery.remove_entry_labels`) — é isso que tira a issue do estado ativo e
   impede o próximo poll de re-despachar — e comenta na issue o candidato, os gates,
   o CI e o estado da review;
7. **credencial**: o push usa um `GIT_ASKPASS` temporário (o arquivo não contém
   segredo e é removido mesmo em falha) e o REST usa o mesmo caminho de auth do
   tracker (`tracker.provider.token`). Nada é escrito em `argv`, no workspace ou em
   log (`Git.sanitize/1` mascara padrões de token na saída dos comandos);
8. **fail-closed de configuração**: `delivery.enabled` sem tracker GitHub, sem
   comando de gates ou com worker remoto falha o preflight de dispatch
   (`Delivery.validate_config/1`) em vez de despachar um worker que não entrega.

## Consequências

- **Positivas:** o pipeline passa a ter uma saída única e auditável (Draft PR) e uma
  definição objetiva de pronto (gates + CI); retry/reconciliação não duplicam
  trabalho; nenhuma regra de negócio do projeto entra no Symphony.
- **Negativas / custos:** o estágio depende da API do GitHub para existir (o
  candidato não é persistido localmente); a observação do CI é **síncrona** dentro do
  run (ocupa o worker até o timeout, por desenho, para não criar estado paralelo no
  orquestrador); `delivery` é local — worker remoto (SSH) exige um estágio remoto
  próprio, ainda pendente.
- **Obrigações:** gates do projeto determinísticos e iguais aos do CI; CI do
  consumidor disparando em `pull_request`; a issue precisa sair do estado ativo pelo
  handoff (sem isso, `agent.max_turns` governa os turnos e não há promoção).

## Alternativas descartadas

| Alternativa | Por que foi descartada |
|---|---|
| publicar por hook `after_run` do workflow | transfere para o consumidor (configuração de shell) um estágio do control plane; sem idempotência, sem CI e fora da observabilidade do Symphony |
| persistir o candidato em arquivo/DB local | cria estado paralelo ao GitHub, que já é a fonte da verdade (PR + checks), e quebra a reconciliação após reinício |
| observar o CI de forma assíncrona no orquestrador | exigiria um ciclo de vida novo (além de `running`/`blocked`/`retry`) que o upstream não tem; a observação síncrona com timeout é menor e mais honesta nesta fase |
| escrever branch/commits pela API do GitHub | duplicaria o trabalho com o workspace git real e perderia o efeito de provedor real (`git push` com o histórico do agente) |
| revisão automática em loop | custo, ruído e falsa garantia (a plataforma decidiu one-shot no ADR-0006) |

## Implementação

- `elixir/lib/symphony_elixir/delivery.ex` (estágio e handoff),
  `delivery/git.ex` (git local + push com askpass), `delivery/github.ex` (REST: PR,
  ref, check runs, labels, comentários, review), bloco `delivery` em
  `config/schema.ex`, preflight em `config.ex`, chamada em `agent_runner.ex` e
  `GitHub.Client.connection/1` (coordenadas/auth reusadas do tracker).
- Testes: `elixir/test/symphony_elixir/delivery_test.exs` (git real contra um
  `origin` bare local e um stand-in determinístico da API), cobrindo gates
  verde/vermelho/timeout, Draft PR idempotente, CI
  verde/vermelho/pendente/ausente, invalidação do candidato por push novo,
  reconciliação sem duplicação, review one-shot, handoff e preflight. Nenhum teste
  da suíte usa rede, GitHub ou credencial.
- Evidência de execução real (fase 6 da plataforma) em
  [../delivery-and-promotion.md](../delivery-and-promotion.md).

