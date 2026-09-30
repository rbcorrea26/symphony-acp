# ADR-0006 — Contrato de aceite legível por máquina (`pipeline_contract`)

- **Status:** aceito
- **Data:** 2026-09-30
- **Relacionado a:** [ADR-0009 da plataforma](https://github.com/rbcorrea26/agentic-dev-environment/blob/main/docs/architecture/adr/0009-execucao-sob-demanda-do-pipeline.md)
  (§4 contrato de aceite, §5 três camadas de verificação),
  [ADR-0005](0005-delivery-stage.md) (estágio de entrega),
  [`../delivery-and-promotion.md`](../delivery-and-promotion.md),
  [`../lifecycle.md`](../lifecycle.md), issue
  [`rbcorrea26/symphony-acp#12`](https://github.com/rbcorrea26/symphony-acp/issues/12),
  regressão medida: issue [#64](https://github.com/rbcorrea26/estudio_angellopes-site/issues/64) /
  PR [#65](https://github.com/rbcorrea26/estudio_angellopes-site/pull/65)

## Contexto

O ensaio E2E no primeiro consumidor real (issue #64 / PR #65 do site Estúdio
Angel Lopes) fechou o caminho técnico — issue → Symphony → ACP → Cline/DeepSeek →
workspace → gates → Draft PR → CI → candidato → review → handoff — e expôs uma
falha de arquitetura clara: **a issue pedia dois arquivos, a implementação alterou
outros e não entregou todos os artefatos exigidos, e os gates do repositório
ficaram verdes**. "Repositório consistente" não é "issue satisfeita".

O ADR-0009 da plataforma decidiu que o aceite é uma camada **separada** dos gates
do repositório e do CI, com um bloco estruturado na issue (`pipeline_contract`)
cujo *schema* fica no fork + template. O que faltava era a decisão do fork sobre
esse schema: quais campos existem, como o contrato chega, o que o parser aceita e
recusa, de onde vem a "evidência obrigatória" e como proibições são detectadas sem
transformar a issue em código.

## Decisão

### 1. O contrato é dado declarativo da issue, nunca código

O parser (`SymphonyElixir.PipelineContract`) extrai um bloco fenced que declare
`pipeline_contract:` (ou um corpo que **comece** com a chave) e valida
versão/tipos/campos. Não existe caminho que avalie conteúdo da issue: sem
`eval`, sem `source`, sem shell, sem `Code.eval_*`; o único "interpretador" é
decodificação de dados (YAML) com limites de tamanho e de itens.

Schema v1 (fechado: campo desconhecido é erro, não é ignorado):

```yaml
pipeline_contract:
  version: 1                 # obrigatório; versão desconhecida é recusada
  scope_mode: strict         # strict | advisory (obrigatório)
  expected_paths: [glob...]  # strict exige ao menos um
  allowed_extra_paths: [glob...]
  required_evidence: [nome...]
  remote_access: false       # ausente = false (proibição explícita é o default)
  deploy: false              # ausente = false
```

- globs: `*` dentro do segmento, `**` atravessa segmentos, `?` um caractere
  (Unicode, não um byte: `docs/?.md` casa `docs/é.md`), `/` no fim significa `/**`;
  padrão absoluto, com `..` ou com `\` é erro de schema (o padrão nunca é resolvido
  no filesystem, só comparado com o change set);
- a chave pode ser escrita **plana ou com aspas** (`pipeline_contract:`,
  `"scope_mode":`, o que um gerador de template produz) e o indicador explícito
  (`? chave`) também é lido: o parser enxerga as mesmas chaves que o decoder YAML
  enxerga, então um contrato declarado nunca é classificado como ausente por causa
  do estilo da chave e uma chave repetida nunca é colapsada em silêncio;
- `strict` sem `expected_paths`, `version` diferente de `1`, `scope_mode`
  inválido, YAML quebrado, dois blocos de contrato no mesmo corpo, bloco acima de
  64 KiB e campo desconhecido **falham o run sem publicar** — contrato que não dá
  para fiscalizar não é contrato;
- corpo sem contrato (`:absent`) **não** é erro: a camada não se aplica e o
  comportamento segue o do ADR-0005.

### 2. As três camadas continuam independentes

| # | Camada | Pergunta | Quem responde |
|---|---|---|---|
| 1 | aceite (`pipeline_contract`) | a issue foi satisfeita? | `Delivery.Acceptance` + `PipelineContract` |
| 2 | gates do repositório | o repositório continua válido? | `delivery.gates` (comando do projeto) |
| 3 | CI | o candidato publicado passou no CI? | check runs do head SHA |

Ordem no run: aceite (escopo, barato e puro) → gates → evidências → publicação.
Um achado `strict` do escopo falha o run **antes** dos gates, de propósito: um
candidato fora do escopo não merece o custo de um gate. Nenhuma das três
camadas substitui a outra.

O escopo é avaliado **duas vezes**: a primeira é o fail-fast descrito acima e a
segunda acontece depois das evidências, porque gates e comandos de evidência rodam
**dentro** do workspace e podem criar ou alterar arquivos. O que é publicado é o
change set final, então é ele que precisa ser aceito: um artefato gerado pelo gate
tem que estar em `allowed_extra_paths` (ou o run falha com
`unexpected_path_changed`).

### 3. Evidência é nomeada: a issue exige o nome, o workflow fornece o comando

`required_evidence` é uma lista de **nomes**, não de comandos (a issue não pode
conter código executável). O workflow mapeia nome → comando em
`delivery.evidence`; o nome reservado `repository-gates` é satisfeito pelo próprio
estágio de gates (que roda imediatamente antes da fase de evidência e, para a
evidência ser avaliada, já passou). Nome exigido sem provider, comando com saída
diferente de 0 ou que estoura `delivery.gates_timeout_ms` é achado — em `strict`
reprova o aceite, em `advisory` é reportado.

Nível de confiança: o comando vem da **configuração do projeto** (`WORKFLOW.md`),
o mesmo nível de `delivery.gates`; a issue contribui apenas com o *nome* exigido.
Uma issue não consegue fazer o pipeline executar nada que o workflow não tenha
declarado, e um nome sem provider é reprovação, não execução implícita.

### 4. Proibição é heurística declarada, não prova de intenção

`remote_access: false` e `deploy: false` são proibições explícitas do default. A
detecção é uma **varredura das linhas adicionadas pelo candidato** (`git diff HEAD`
de arquivos rastreados — o processo filho é lido até o cap e encerrado nele, o diff
inteiro nunca é capturado — + conteúdo de arquivos não rastreados, ambos limitados), com
regras fixas e versionadas neste fork: `kubectl apply/create/...`, `terraform
apply/destroy`, `helm upgrade/install/...`, `ansible-playbook`, `docker push`,
`npm/yarn/pnpm publish`, `gh release create/upload`, `aws deploy|cloudformation
deploy|s3 sync`; e `ssh/scp/sftp`, `rsync` para host remoto, `ssh://`, `git clone
git@`, `wp @host|--ssh=`, `mysql/mysqldump/psql -h`. O parse do diff mantém o estado
do arquivo: `+++ b/path` é cabeçalho **só fora de hunk**, então uma linha adicionada
que comece com `++ b/` é varrida como conteúdo (e não rouba o path das linhas
seguintes). Uma linha produz no máximo um
achado (primeira regra que casa), até 5 achados por tipo, com o trecho truncado e
mascarado porque o achado vai para log e comentário no GitHub. Um `true` no
contrato desliga aquele tipo.

**Importante — `deploy: true` não concede capacidade.** O contrato é declarativo e
**restritivo**: escrever `true` significa apenas "este contrato não proíbe deploy",
e qualquer outra política (plataforma, projeto, ambiente) continua valendo. O
aceite nunca libera o que o projeto não tem.

### Verificável e não verificável (declarado, não fingido)

| Aspecto | Verificável? | Mecanismo |
|---|---|---|
| paths entregues/autorizados | sim, determinístico | change set do git (`--porcelain -z -uall`) |
| evidência exigida | sim | exit code do comando declarado no workflow |
| comando proibido **presente** | sim (positivo) | varredura de padrões das linhas adicionadas |
| **ausência** de acesso remoto/deploy na execução | **não** | o fork não observa rede/processos do agente; "sem achado" ≠ prova de ausência |
| conteúdo/qualidade do entregue | não | gates, review e arquiteto |

A distinção é declarada na resposta (`limits`) e no comentário de handoff, e não
convertida em `PASS` silencioso.

### Segurança da entrada não confiável

- YAML: só decodificação de dados com tipos explícitos; tags recusadas pelo decoder
  (`!foo`, `!ruby/object`, `!!python/...`) e âncoras recusadas pelo parser antes de
  decodificar (sem alias/expansão, e portanto sem bomba de aliases) — a detecção de
  âncora ignora comentários e scalars com aspas, onde `&` é dado;
- duplicidade ambígua é recusada, nunca "escolhida": dois blocos, duas chaves
  `pipeline_contract` e uma **mesma chave repetida dentro do mapeamento**
  (`duplicate_field`). A contagem é feita nos **nós do parser YAML** (chave com
  aspas, com tag, com âncora ou explícita é a mesma chave; chaves iguais são
  contadas antes de o decoder colapsá-las), e o texto bruto não decide presença: ele
  só pode *ampliar* o conjunto de falhas (um bloco que cita a chave e não pode ser
  decodificado é erro, nunca ausência — e um bloco que só **menciona** a chave dentro
  de um scalar não é declaração);
- nenhum dado do contrato chega a um shell: o comando executado vem de
  `delivery.gates`/`delivery.evidence` (configuração do projeto) e a issue só
  contribui com **nomes** de evidência;
- path traversal: padrão absoluto, com `..` ou com `\` é erro de schema; o match é
  textual e ancorado, sem resolução de filesystem, então symlink não move escopo;
- leitura de arquivo não rastreado usa `lstat` e recusa o que não for arquivo
  regular (um symlink não faz a varredura ler fora do workspace);
- achado que vai para log/comentário é mascarado, truncado e sem quebras de linha;
  o texto humano tem `<` neutralizado (uma alteração do candidato não reescreve o
  comentário nem forja marcação de handoff).

### 5. Sem candidato novo não há aceite a aplicar

Quando o change set está vazio (ciclo `--resume-only` sobre candidato já
publicado, ou nada a publicar), o relatório diz `not_applicable` em vez de
reprovar: o candidato que está sendo retomado foi aceito pelo ciclo que o criou.
O relatório aparece no comentário de handoff e no log; nunca é inventado um
"aceite verde".

### 6. O veredicto é dado estruturado, não booleano

O aceite devolve `SymphonyElixir.Delivery.Acceptance.Result`:

```
%Result{status, contract_version, mode, findings, evidence, change_set, limits}
```

- `status`: `:pass` | `:fail` | `:advisory` | `:not_configured` (issue sem
  contrato) | `:not_applicable` (sem change set novo);
- `findings`: `SymphonyElixir.PipelineContract.Finding` com `code` estável
  (`invalid_contract`, `expected_path_missing`, `unexpected_path_changed`,
  `required_evidence_missing`, `required_evidence_failed`,
  `forbidden_deploy_detected`, `forbidden_remote_access_detected`), `category`
  (`contract`/`scope`/`evidence`/`forbidden_operation`), `message` e `path`;
  **sem score e sem ranking** — quem bloqueia é o `mode`;
- `evidence`: registros observados (nome, status, comando; nunca saída, duração ou
  contagem transitória);
- `limits`: o que **não** foi verificado (verificação heurística de proibição,
  varredura truncada, conteúdo não avaliado), para que um `pass` não seja lido como
  prova.

O veredicto aparece no `result` de `Delivery.run/3`, no log
(`Delivery acceptance passed|diverged|failed`) e no comentário de handoff como
marcação + JSON (`<!-- acceptance:result:<sha> -->`), que é a interface estável para
a máquina de estados da review (#13) e para o architect runner (#14). Nada de
rótulo novo e nada de arquivo de estado: a evidência continua transitória
(PR/CI/comentário), como decidido no ADR-0006 da plataforma.

Invariante operacional do handoff: *promotion state must not advance if the
machine-readable verdict was not durably persisted* — o comentário (com o JSON) é
escrito **antes** do rótulo de handoff e da remoção do rótulo de entrada; se a
escrita falhar, a issue não é promovida e nada de estado avança.

Limite declarado:
quando o aceite reprova, o run falha e **não** publica nem comenta (a evidência do
bloqueio fica no log; o estado persistido de bloqueio é escopo da #13).

## Consequências

- **Positivas:** o aceite deixa de ser otimista e passa a ser verificável e
  auditável; a regressão #64/#65 (gates verdes, artefatos faltando) vira teste
  que reprova; o schema é pequeno, versionado e sem superfície de execução;
  `advisory` permite introduzir o contrato em consumidor real sem quebrar o
  fluxo, e a decisão final fica na review arquitetural.
- **Negativas / custos:** mais uma superfície de configuração no `WORKFLOW.md`
  (`delivery.evidence`) e mais um campo que a issue pode errar; a varredura de
  proibição é heurística e pode produzir falso positivo (a issue pode autorizar com
  `true`, o workflow pode usar `advisory`, o dono do repo decide); evidência
  nomeada exige que o consumidor nomeie o que já testa.
- **Obrigações:** nenhum `ready-for-human` sem as três camadas; nenhuma
  evidência exigida pode passar sem provider; nenhum conteúdo da issue é
  executado; a documentação do consumidor (template) precisa ensinar o bloco.

## Alternativas descartadas

| Alternativa | Por que foi descartada |
|---|---|
| considerar os gates do repositório como aceite | foi exatamente a falha medida no #64/#65 |
| contrato em arquivo do projeto (`pipeline_contract.yml`) em vez de na issue | o escopo é da issue; no projeto ele viraria config global e deixaria de responder "esta issue foi satisfeita?" |
| `required_evidence` com comandos dentro da issue | transformaria a issue (entrada não confiável) em execução de código |
| sinais de aceite avaliados pelo próprio agente | evidência fraca e não reproduzível (ADR-0006 da plataforma) |
| `scope_mode` com default `advisory` | fiscalização silenciosa que não fiscaliza; ausência de contrato já é o caminho "sem fiscalização" |
| default `true` para `remote_access`/`deploy` | proibição permissiva por omissão; o custo de um falso positivo é um relatório, o custo de um deploy acidental não é |
| detectar proibição por padrão de *caminho* (ex.: `deploy/`) | ruído alto (diretório de infraestrutura é comum) e baixa correlação com a ação; a varredura de linhas adicionadas casa com o que o candidato faz |
| criar um arquivo local com o veredicto do aceite | estado paralelo ao GitHub, que já é a fonte da verdade (ADR-0005) |

## Implementação

- `elixir/lib/symphony_elixir/pipeline_contract.ex` — parser/schema v1, matching de
  glob (o padrão é compilado uma vez por avaliação do change set), achados de escopo
  e de proibição (puros).
- `elixir/lib/symphony_elixir/delivery/acceptance.ex` — gate impuro: lê o change
  set, roda as evidências exigidas, decide por modo, resume o relatório e persiste o
  veredicto cortado por bytes (16 KiB, com `omitted`).
- `elixir/lib/symphony_elixir/delivery/gates.ex` — runner único de comando com
  timeout, usado por gates e evidências.
- `elixir/lib/symphony_elixir/delivery/git.ex` — `change_set/1` (porcelain `-z
  -uall`: rename = destino + origem como deleção, copy só o destino, arquivo não
  rastreado individual) e `added_lines/1` (leitura limitada do `git diff`, que é
  encerrado no cap, + não rastreados limitados).
- `elixir/lib/symphony_elixir/delivery.ex` — ordem das camadas, `contract` no
  resultado e linha do aceite no comentário de handoff.
- `elixir/lib/symphony_elixir/config/schema.ex` — bloco `delivery.evidence`
  (nome não vazio → comando não vazio).
- Testes: `pipeline_contract_test.exs` (schema, glob, escopo, proibições),
  `delivery_acceptance_test.exs` (gate sobre git real, evidências, resume,
  truncamento, arquivo ilegível/binário) e os casos ponta a ponta em
  `delivery_test.exs` (bloqueio `strict`, regressão #64/#65, `advisory`,
  evidência verde/vermelha, contrato inválido e segundo ciclo).
- O que continua **igual** no upstream: nenhum arquivo do caminho Codex/Symphony
  residente muda de comportamento; sem `delivery.enabled` e sem contrato, o fluxo
  é o do ADR-0005 (`delivery` desligado = upstream puro).

