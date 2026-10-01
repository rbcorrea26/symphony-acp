# Contrato de aceite (issue → `pipeline_contract`)

Documento operacional da camada de **aceite da issue** do estágio de entrega. A
decisão está em [adr/0006](adr/0006-acceptance-contract.md); aqui ficam o schema,
a semântica, os códigos, o que é verificável e o que **não** é.

> `acceptance PASS` ≠ `repository gates PASS` ≠ `CI PASS` ≠ `review PASS` ≠ `architect PASS`.
> São cinco coisas diferentes, medidas por cinco agentes diferentes, e nenhuma
> substitui a outra. Este documento trata só da primeira.

## 1. As três camadas do run de entrega

| # | Camada | Pergunta | Quem responde | Quando |
|---|---|---|---|---|
| 1 | **aceite** (`pipeline_contract`) | a **issue** foi satisfeita? | `Delivery.Acceptance` + `PipelineContract` | antes dos gates (escopo) e depois deles (evidências) |
| 2 | **gates do repositório** | o **repositório** continua válido? | `delivery.gates` (comando do projeto) | antes de publicar |
| 3 | **CI** | o **candidato publicado** passou no CI? | check runs do head SHA | depois de publicar |

A review (`waiting-review`/`rework`) e o `architect runner` são as camadas
seguintes e **ainda não existem** (issues #13 e #14 deste repositório). O handoff
atual continua sendo o do ADR-0005.

## 2. Schema v1

O contrato é um bloco no **corpo da issue** (bloco fenced que declare
`pipeline_contract:`, ou um corpo que comece com a chave):

```yaml
pipeline_contract:
  version: 1                 # obrigatório; outra versão é recusada
  scope_mode: strict         # obrigatório: strict | advisory
  expected_paths:            # obrigatório em strict; globs relativos ao repo
    - docs/changes/2026-09-30-pipeline-e2e-smoke.md
    - tests/agent/run-tests.sh
  allowed_extra_paths: []    # globs autorizados além dos esperados
  required_evidence:         # nomes; o workflow fornece os comandos
    - agent-tests
    - repository-gates
  remote_access: false       # ausente = false (proibição explícita)
  deploy: false              # ausente = false
```

Regras do parser (`SymphonyElixir.PipelineContract`):

| Entrada | Comportamento |
|---|---|
| sem contrato no corpo | `:absent` → camada **não configurada** (comportamento anterior preservado) |
| YAML inválido | erro determinístico `{:invalid_yaml, _}` → reprova o run |
| `version` ≠ 1 | `{:unsupported_version, v}` → reprova |
| campo desconhecido | `{:unknown_fields, [...]}` → reprova |
| tipo errado (lista/escalar/flags) | `{:invalid_field, ...}` / `{:invalid_flag, ...}` → reprova |
| `scope_mode` ausente/desconhecido | `{:invalid_scope_mode, v}` → reprova |
| `expected_paths` vazio em `strict` | `:strict_requires_expected_paths` → reprova |
| lista vazia em `allowed_extra_paths`/`required_evidence` | válido (é a ausência de autorização/exigência) |
| path absoluto, com `..`, com `\` ou vazio | `{:invalid_pattern, _, _}` → reprova |
| dois blocos, ou duas chaves `pipeline_contract` no mesmo bloco | `{:ambiguous_contracts, n}` / `{:duplicate_contract_key, n}` → reprova (a contagem vem dos **nós do parser YAML**, antes de o decoder colapsar chaves iguais) |
| chave escrita com aspas (`"scope_mode":`, `'scope_mode':`), com tag (`!!str`), com âncora ou com o indicador explícito (`? scope_mode`) | é a **mesma** chave que o decoder lê: presença, escopo e duplicidade continuam sendo verificadas |
| uma mesma chave repetida no mapeamento (bloco, flow ou `? chave`) | `{:duplicate_field, "scope_mode"}` → reprova |
| `pipeline_contract:` **dentro de um scalar** (exemplo em bloco de documentação) | não é declaração: o parser não vê a chave ali, então o corpo segue `:absent`; um bloco que não pode ser decodificado **e** cujo texto cita a chave é erro, nunca ausência |
| conteúdo de block scalar (`key: \|`, `key: >-`, `- \|`) | é **texto**: a chave ou a âncora escrita dentro dele não conta (o escalar termina na primeira linha menos indentada) |
| cabeçalho de block scalar com os dois indicadores (`\|2-`, `\|-2`) | as duas ordens valem: o conteúdo é texto nas duas |
| string com aspas que atravessa linhas físicas | a continuação continua sendo **scalar** (o estado da citação sobrevive ao `\n`), então `&notes` ali não é âncora |
| aspas que **não fecham** em nenhuma linha do bloco (`foo: 'unterminated`) | o scalar não existe (o decoder não o lê): a citação não pode blankar as linhas seguintes, então um `pipeline_contract:` escrito depois dela continua sendo observado e o bloco **falha fechado**, nunca vira ausência |
| aspas logo depois de `:` **sem separação** (`foo:'unterminated`, `scope_mode:'advisory'`) | perante o YAML isso é **plain scalar**, não scalar com aspas: a dica textual não entra em estado de citação e a declaração seguinte continua visível (com separação `foo: 'unterminated`, a citação é válida e não fecha: vale a linha acima) |
| bloco **decodificável** que não lê a chave mas cujo texto a declara em posição de chave | o token foi absorvido por um scalar malformado (`foo:'unterminated` transforma o `pipeline_contract:` seguinte em parte de uma chave plana multi-linha) ou é uma declaração aninhada em outro mapeamento: o bloco é candidato a contrato e o decode reporta `:missing_pipeline_contract_key` → reprova, nunca ausência |
| bloco **ilegível** cujo texto cita a chave em posição de chave (mesmo dentro de um scalar) | a decisão é sobre o texto bruto, então a chave é observada: reprova, nunca ausência (o preço conservador de não deixar nenhuma heurística esconder uma declaração) |
| cerca de abertura/fechamento com **mais de três espaços** de indentação (ou com tab) | é código indentado, não cerca: não abre nem fecha o bloco, então o conteúdo depois dela continua sendo observado (uma pseudo-cerca não pode truncar o YAML) |
| cerca de fechamento | mesmo marcador da abertura, comprimento ≥ o da abertura e **nada além de espaços** depois do marcador: uma linha como ` ```not-a-close ` é conteúdo do bloco (não trunca o YAML nem esconde os campos que vêm depois) e uma linha de abertura com info string (` ```yaml `) nunca fecha |
| cerca de fechamento com o mesmo marcador e mais caracteres que a abertura | fecha o bloco (CommonMark): a prosa seguinte não é lida como YAML |
| `pipeline_contract:` dentro de um scalar **e** bloco que não pode ser decodificado | a dica de chave roda no texto com o scalar blankado: um scalar não declara o contrato (nem sequer para reprovar), mas um bloco que cita a chave fora de scalar segue falhando fechado |
| aspas simples escapada (`''`) dentro de scalar | continua sendo **um** scalar (`'docs/it''s &notes.md'` não é scalar + âncora) |
| padrão que não é UTF-8 (ex.: um `!!binary`) | `{:invalid_pattern, _, :not_utf8}` → reprova (a comparação de paths é sobre UTF-8) |
| tag YAML (`!foo`, `!ruby/object`, `!!python/...`) | `{:invalid_yaml, %{type: :unrecognized_node}}` → reprova |
| âncora (`&name`) | `{:anchors_not_supported, "&name"}` → reprova (alias/expansão não têm uso no schema) |
| bloco com mais de um documento YAML (`---`) | a chave é contada em todos os documentos do bloco e o decoder lê um deles: um contrato que não esteja no documento decodificado é `:missing_pipeline_contract_key` → reprova (nunca é lido "o contrato errado") |
| bloco > 64 KiB, lista > 256 itens, padrão > 512 chars | reprova |

O parser **decodifica dados, nunca executa**: sem `eval`, `source`, shell ou
interpolação do contrato em comando. Nada do contrato chega a um shell; os padrões
são comparados (regex ancorada) com o change set, nunca resolvidos no filesystem.

Quem decide se o corpo **declara** o contrato é o **parser YAML**, não uma regex:
a chave é contada nos nós do parser (com `maps_as_keywords`, que preserva chaves
repetidas e não guarda comentários) *antes* de o decoder colapsar duplicatas, então
estilo de chave e duplicidade ambígua não dependem de forma textual. A regex de
chave existe só como **dica textual que amplia o conjunto de falhas**, nos dois
lugares em que o parser não consegue responder:

- bloco que **não pode ser lido** (`:invalid`, ou acima do cap de tamanho): a decisão
  é sobre o texto **bruto**, sem blankar nada — assim nenhuma heurística sobre scalars
  pode esconder uma declaração. O preço declarado é conservador: um scalar de um bloco
  ilegível que cite a chave em posição de chave (por exemplo um `pipeline_contract:`
  dentro de um block scalar num documento quebrado por outro motivo) é reprovado em vez
  de virar ausência;
- bloco **legível que não lê a chave**: a decisão vem do que o **decoder leu**. Se
  alguma chave lida contém o token — o caso de um scalar malformado
  (`foo:'unterminated`) que absorve o `pipeline_contract:` seguinte para dentro de uma
  chave plana mais longa, ou o de uma declaração aninhada em outro mapeamento — e o
  texto a declara em posição de chave, o bloco é reprovado
  (`:missing_pipeline_contract_key`). Se o token está dentro de um **valor** (block
  scalar, string com aspas, comentário), ele não é chave nenhuma: não declara nada e o
  corpo segue `:absent` — é o que mantém um exemplo de documentação ou uma menção em
  prosa fora do contrato.

O blanking de scalar (comentário, string com aspas, block scalar) continua existindo
para as decisões que **não** parseiam o bloco: a recusa de âncora estrutural (o grafo
de alias nunca é expandido) e o cap de tamanho. Ele usa as mesmas separações que o
decoder exige — um scalar com aspas ou um comentário só começa onde um nó pode
começar, nunca colado a um `:` — e uma citação que não fecha em nenhuma linha do bloco
não blanka as linhas seguintes (o blanking é refeito linha a linha, onde nenhum estado
sobrevive ao `\n`).

## 3. Semântica de escopo

`expected_paths` significa **"o candidato entrega este path"**, não "o path existe
no repositório": a comparação é com o **change set do candidato efetivo** (o que será
publicado), lido do Git contra a merge base com a branch base
(`Git.effective_change_set/2`, `git diff --name-status -z --find-renames --find-copies`
+ `git ls-files --others -z`). Um arquivo que já existia na base e não foi tocado
**não satisfaz** o contrato — foi exatamente o caso #64.

O sujeito é o **conteúdo que o run pretende promover**, e não uma escolha entre
worktree e candidato: o diff da base para o **estado final do workspace** cobre, numa
leitura só, o candidato já commitado (retomada), as alterações atuais de arquivos
rastreados — inclusive uma que desfaz um commit — e os arquivos não rastreados que o
`git add -A` publicaria. O conteúdo do worktree simplesmente vence o commit, como no
commit que o run vai criar; não há duas listas para reconciliar nem precedência a
adivinhar, e um path aparece **uma vez**, no estado final (um rename é o rename
efetivo, uma deleção do candidato desfeita no worktree deixa de ser mudança). O
overlap possível entre as duas leituras — um path que o índice deixou de rastrear mas o
worktree ainda guarda — é resolvido pelo **worktree**: o path é reportado como não
rastreado (`??`, o que `add -A` publicaria), nunca como a deleção que a promoção não
tem.

A leitura do change set **falha fechada**: acima de 5 000 entradas é erro
(`change_set_too_large`, contando as entradas materializadas do diff e as não
rastreadas juntas) e um path que não é UTF-8 válido é recusado
(`change_set_not_utf8`) em vez de derrubar o run ou aceitar dado parcial — o escopo
nunca é decidido sobre um change set incompleto.

O escopo é avaliado **duas vezes** no run: antes dos gates (fail-fast) e **depois**
das evidências, porque gates e comandos de evidência rodam dentro do workspace e
podem criar arquivos. O que é publicado é o change set final, então é ele que
precisa ser aceito: um artefato (`coverage/`, `evidence.txt`) entra no candidato e
tem que estar em `allowed_extra_paths` — caso contrário o run falha com
`unexpected_path_changed`.

| Caso no candidato | Como aparece no change set | `expected_paths` | `allowed_extra_paths` |
|---|---|---|---|
| add (arquivo novo) | `?? path` (individual, `-uall`) | satisfaz se casar | autoriza se casar |
| modify | ` M path` | satisfaz se casar | autoriza se casar |
| delete | ` D path` | satisfaz (a remoção é a entrega) | autoriza |
| rename | `R  destino` **e** `D  origem` | satisfaz pelo destino; a origem removida precisa estar autorizada | autoriza destino e origem |
| copy | `C  destino` (a origem permanece) | satisfaz pelo destino | autoriza pelo destino |

Divergências: path esperado não entregue → `expected_path_missing`; path alterado
fora de `expected_paths` ∪ `allowed_extra_paths` → `unexpected_path_changed`.

O rename aparece como **duas** mudanças de propósito: o git removeu a origem, e um
contrato `strict` que autorizasse apenas o destino seria um caminho para apagar um
arquivo não autorizado (renomeando-o para um path autorizado) sem nenhum achado. O
`copy`, que deixa a origem no lugar, não gera deleção nenhuma.

Globs (`*` dentro do segmento, `**` atravessando, `?` um caractere, `/` no fim =
`/**`) existem porque o escopo real raramente é um único arquivo (documentação por
data, diretório de evidência gerada) e a implementação é segura por construção:
regex ancorada, sem resolução de filesystem, padrão validado (sem absoluto, `..`,
`\`). A alternativa (só match exato) está descartada no ADR.

## 4. Semântica de evidência

`required_evidence` é uma lista de **nomes** (slug minúsculo). O registry é:

1. o nome reservado **`repository-gates`** — satisfeito pelo próprio estágio de
   gates (que roda imediatamente antes e, para a evidência ser avaliada, passou);
2. os nomes declarados pelo projeto em `delivery.evidence` (nome → comando).

Um nome sem provider é `required_evidence_missing`; comando com exit ≠ 0 ou que
estoura o orçamento é `required_evidence_failed`. A evidência
**nunca é inventada pelo agente**: ela é o exit code de um comando declarado no
workflow do projeto, executado no workspace da issue. Não se persiste duração,
contagem de testes, SHA ou saída de comando — só nome, status e comando.

A fase de evidência tem **um orçamento**, não um por comando: como o
`required_evidence` vem de entrada não confiável (até 256 nomes), todos os
comandos dividem `delivery.gates_timeout_ms`; quando o orçamento acaba, o que
faltou executar é `required_evidence_failed` com o status `deadline_exceeded`
(um contrato não pode ocupar o worker por horas multiplicando o timeout).

## 5. Proibições: o que é verificável e o que não é

| Aspecto | Verificável? | Mecanismo |
|---|---|---|
| paths entregues/autorizados | **sim, determinístico** | change set efetivo do git (diff base → estado final + não rastreados) |
| evidência exigida | **sim** | exit code do comando declarado no workflow |
| comando proibido **presente** nas linhas adicionadas | **sim (positivo)** | varredura de padrões fixos (ADR-0006 §4) |
| **ausência** de acesso remoto/deploy na execução | **não** | o pipeline não observa rede/processos do agente: um `PASS` significa "nenhum achado na varredura", não prova de ausência |
| conteúdo/qualidade do que foi entregue | **não** | é dos gates, da review e do arquiteto |

Essa distinção é declarada na resposta (`limits`) e no comentário de handoff, em
vez de virar `PASS` silencioso. A varredura é limitada e **declara cada limite
atingido** (`change_scan_truncated`): 1 MiB de texto de diff (lido do processo filho
e cortado no cap — o `git diff` é encerrado nesse ponto, o diff inteiro nunca é
capturado na memória), 200 arquivos não rastreados, 262 144 bytes por arquivo não
rastreado, 2 000 linhas adicionadas, 5 achados por tipo e trecho de 80 caracteres. O
limite residual declarado: a captura de `git ls-files` (e a do `git diff` do sujeito) é
proporcional ao número de paths do candidato (o change set é limitado a 5 000 entradas); o
*parse* do formato `--name-status` é limitado **enquanto lê** — um campo NUL-delimited por
vez, parando na primeira entrada acima do cap, sem materializar a lista inteira antes —, a
leitura dos não rastreados compartilha o mesmo cap e as estruturas construídas aqui são
limitadas.
Consequência declarada dessa leitura incremental: um input enorme cujo *tail* não é
UTF-8 devolve `change_set_too_large` (o tail não chega a ser lido), enquanto um path não
UTF-8 **dentro** do cap devolve `change_set_not_utf8` — as duas falham fechado.

**Varredura parcial não passa por completa**: quando o cap é atingido (no diff lido,
nos arquivos ou nas linhas), o veredicto ganha o finding
`prohibition_scan_truncated` — em `strict` o run **falha** (nada é publicado) e em
`advisory` a divergência é reportada e o handoff continua — além do limite
`change_scan_truncated`, sempre declarado. Um contrato que desligou as duas
proibições (`remote_access: true` e `deploy: true`) não tem o que certificar: aí o
cap é só um limite, sem finding. O teto de **achados** por tipo (`truncated` da
varredura de regras) é outro caso: ele nunca esconde uma proibição encontrada, só
limita quantas são listadas.

`deploy: true` / `remote_access: true` **não concedem capacidade**: significam
apenas "este contrato não proíbe". Quem autoriza deploy é a política da plataforma
/do projeto — o aceite é declarativo e restritivo, nunca um mecanismo de permissão.

## 6. `strict`, `advisory` e contrato ausente

| Situação | Status do veredicto | Efeito no run |
|---|---|---|
| contrato ausente | `:not_configured` | nenhum (comportamento anterior, ADR-0005) |
| workspace com o candidato publicado (HEAD ≠ base) | `:pass` / `:fail` (recalculado do Git, com o worktree incluído) | o conteúdo efetivo é reavaliado antes de promover (seção 6.1) |
| workspace cujo worktree **desfaz por inteiro** o candidato (HEAD ≠ base, change set efetivo vazio) | `:pass` / `:fail` em `strict`, `:advisory` em `advisory` | é **sujeito**: o run publicaria o commit que desfaz o candidato, então o contrato em vigor é avaliado sobre o change set vazio (`expected_path_missing`, evidências executando) |
| workspace sem sujeito a promover (HEAD na base **e** change set efetivo vazio) | `:not_applicable` | nenhum: o run não publicaria nada |
| `strict`, sem achados | `:pass` | segue: gates → evidências → publicação |
| `strict`, com achados | `:fail` | run falha **sem publicar** (nada de branch/PR/rótulo/comentário) |
| `strict`, varredura de proibição **truncada** | `:fail` (`prohibition_scan_truncated`) | run falha sem publicar: um scan parcial não certifica ausência de proibição |
| `advisory`, com achados | `:advisory` | publica normalmente; achados no log e no comentário |
| contrato inválido | `:fail` (`mode: nil`) | run falha sem publicar (`invalid_contract`) |

Idempotência: o veredicto é função de (contrato, change set efetivo, comandos de
evidência), então repetir o aceite sobre o mesmo candidato dá o mesmo resultado; um
retry não publica nada em caso de falha e não duplica o comentário em caso de sucesso.
O comentário do handoff é o **artefato autoritativo do veredicto do candidato**: ele é
criado uma vez por SHA e **substituído** quando o mesmo candidato é reavaliado com outro
payload (seção 8) — identidade pelo candidato, conteúdo pela impressão digital.

### 6.1 Retomada (`--resume-only`) de um candidato publicado

Um workspace com um candidato publicado não é "nada a aceitar", nem "só o delta do
worktree". O aceite é **recalculado sobre o conteúdo que o run vai promover**, lido do
Git, e o veredicto anterior **nunca é reusado**:

- o sujeito é o **candidato efetivo**: o diff da merge base com a branch base
  (`delivery.base_branch`) para o **estado final do workspace**, ou seja o candidato já
  commitado **mais** as alterações rastreadas atuais **mais** os arquivos não rastreados
  (o que o gates ou uma evidência escreveu depois da publicação entra na avaliação, e o
  que o worktree desfez deixa de entrar) — nunca uma escolha entre "worktree" e
  "candidato";
- rename continua sendo destino + origem **como deleção** e copy só o destino (no formato
  `--name-status` a origem vem **antes** do destino), e as duas leituras (diff e
  não rastreados) compartilham o cap de 5 000 entradas;
- a varredura de proibição lê as linhas adicionadas **do diff do sujeito** (o mesmo diff
  contra a base, mais os não rastreados que estiverem no worktree);
- as evidências exigidas pelo contrato **em vigor** rodam de novo: um contrato que passou
  a exigir uma evidência nova (ou cujo provider passou a falhar) não é "aceito pelo ciclo
  que publicou";
- uma mudança material do contrato depois da publicação (`expected_paths` diferente, uma
  proibição nova, uma evidência nova) é reavaliada de forma determinística contra o
  candidato efetivo: ou ele satisfaz o contrato novo, ou o run falha sem promover nem
  comentar;
- `not_applicable` responde a **"existe sujeito a promover?"**, não a "o change set efetivo
  está vazio?": ele fica reservado ao workspace que está na base (`HEAD` == merge base) e
  não tem nada que a promoção carregaria. Um worktree que **desfaz por inteiro** o
  candidato publicado deixa o change set efetivo vazio e ainda assim é sujeito — o commit
  que desfaz o candidato é o que o run publicaria —, então o escopo é avaliado sobre esse
  estado final (`expected_path_missing` para o que o candidato entregava, evidências
  exigidas executando) em vez de o revert ser promovido como "nada a aceitar"; nenhuma
  entrada é inventada para deixar o change set não vazio. Os quatro casos: (A) `HEAD` ==
  base e change set vazio → `not_applicable`; (B) `HEAD` ≠ base → sujeito, com worktree
  limpo ou sujo; (C) `HEAD` == base com change set não vazio → sujeito (o primeiro ciclo);
  (D) `HEAD` ≠ base com o worktree desfazendo o candidato por inteiro → sujeito, com change
  set efetivo vazio;
- as duas fases (escopo e evidência) usam a **mesma** noção de sujeito — `HEAD` ≠ base **ou**
  change set efetivo com entradas, lidos no mesmo passo —, então nenhum estado roda uma fase
  e pula a outra;
- uma branch base que não resolve é erro (`delivery_base_missing`) — nunca um diff vazio
  lido como "o candidato não mudou nada";
- a promoção do run de retomada (reconciliar o candidato já publicado) continua amarrada
  ao SHA: um head de branch diferente do HEAD local falha com `delivery_candidate_replaced`.

Limite declarado: o sujeito do aceite é o que o run **vai promover**. Num ciclo de
criação (sem candidato publicado) isso é o worktree contra a base; num ciclo de retomada
é o candidato commitado **mais** o worktree atual. Nenhum caminho de retomada transforma
ausência de execução de evidência em `PASS`: sem sujeito a promover o status é
`not_applicable`, e com sujeito as evidências exigidas rodam (falha continua fail-closed
em `strict` e advisory em `advisory`).

## 7. Códigos de finding

| Código | Categoria | Significado |
|---|---|---|
| `invalid_contract` | `contract` | o contrato existe e não é fiscalizável (versão/campo/tipo/duplicidade/âncora/YAML) |
| `expected_path_missing` | `scope` | path esperado não faz parte do change set do candidato |
| `unexpected_path_changed` | `scope` | path alterado fora de `expected_paths` ∪ `allowed_extra_paths` (inclui a origem de um rename, que é uma deleção) |
| `required_evidence_missing` | `evidence` | nome exigido sem provider no registry |
| `required_evidence_failed` | `evidence` | provider com exit ≠ 0, timeout ou orçamento da fase esgotado |
| `prohibition_scan_truncated` | `forbidden_operation` | a varredura das linhas adicionadas atingiu o cap: ausência de proibição não é certificável sobre um scan parcial (bloqueia em `strict`) |
| `forbidden_deploy_detected` | `forbidden_operation` | regra de deploy casou em linha adicionada |
| `forbidden_remote_access_detected` | `forbidden_operation` | regra de acesso remoto casou em linha adicionada |

Cada finding tem `code`, `category`, `message` (humano) e `path` (quando aplicável).
Não há score nem ranking: quem decide bloquear é o `mode`.

## 8. Persistência e o que a #14 vai consumir

O veredicto completo é devolvido por `Delivery.run/3` (`result.contract`) e
persistido no comentário de handoff como marcação + JSON:

```text
<!-- acceptance:result:<candidate-sha>:<fingerprint> -->
{"status":"advisory","contract_version":1,"mode":"advisory","findings":[...],"evidence":[...],"limits":[...]}
```

O JSON é a interface estável para a máquina de estados da review (#13) e para o
architect runner (#14): eles leem `status`, `findings[].code`/`category`/`path` e
`limits`, sem parsear prosa. O payload é **limitado a 16 KiB por construção**: acima
disso ele é persistido de forma compacta — os comandos de evidência (a parte maior)
saem primeiro e depois os arrays de findings/evidências são cortados até caber no cap,
medido no JSON de verdade (não estimado) — e o campo `omitted` diz quantos ficaram de
fora, com `persisted` marcando a compactação. Perder o texto do comando (ou o
excedente dos arrays) é melhor que perder o veredicto, e o comentário do GitHub tem
limite de tamanho.

**Um candidato tem um artefato autoritativo, e ele é o veredicto atual.** A
identidade do artefato é o comentário que carrega o marcador do candidato
(`<!-- delivery:candidate:<sha> -->`) e a marcação de aceite leva a **impressão
digital** do payload (`SHA-256` do JSON persistido, `Acceptance.payload_fingerprint/1`):

- mesmo candidato **e** mesma impressão digital → operação idempotente: nada é escrito
  (retry não duplica comentário);
- mesmo candidato **e** impressão diferente → o comentário é **atualizado**
  (`PATCH /issues/comments/:id`): o veredicto antigo não continua como estado
  autoritativo quando o contrato mudou, uma evidência passou a falhar ou o modo mudou;
- candidato diferente → artefato próprio (o marcador carrega o SHA);
- falha ao escrever/atualizar → o run falha **antes** de qualquer rótulo de promoção,
  então nenhum rótulo indica um estado cujo aceite não esteja persistido;
- o comentário é escrito **antes** dos rótulos de promoção (mesmo invariante de antes).

A comparação é por identidade explícita + impressão digital do payload, nunca por
heurística de prosa ou por "o comentário existe". Limites declarados: comentários
antigos (de outro candidato, ou de um payload anterior do mesmo candidato, se o GitHub
não permitir substituir) permanecem como **histórico** e não são lidos como o veredicto
vigente; a leitura de comentários existentes é a primeira página da API
(`per_page=100`), o mesmo limite do estágio de entrega — um artefato fora dela não é
visto, e nesse caso o run escreve o veredicto corrente (nunca deixa de persistir).
Quando o aceite **reprova**, o run falha e **não** publica nem comenta (a evidência
fica no log do run) — o estado de bloqueio persistido no GitHub é escopo da #13.

O veredicto é do **conteúdo aceito**: ele é calculado sobre o workspace antes de
publicar, e o comentário carrega o SHA do candidato publicado. Se o head da branch
observado no fim for outro commit (um push concorrente), o run falha com
`delivery_candidate_replaced` em vez de associar o veredicto a um candidato que
ninguém aceitou.

## 9. Segurança

- o contrato é **entrada não confiável** (corpo da issue): decodificação de dados
  com tipos explícitos, tags YAML recusadas, âncoras recusadas, limites de tamanho
  e de itens, sem `eval`/`source`/shell; a presença e a duplicidade da chave são
  contadas nos **nós do parser** (uma chave com aspas, com tag ou explícita é a
  mesma chave; duas chaves iguais são duas), e o texto bruto só pode *acrescentar*
  falha, nunca declarar ausência — inclusive depois de um scalar malformado, que
  não pode blankar as linhas seguintes nem esconder uma declaração real;
- **globs**: o padrão é transformado em uma fonte de regex cujos literais passam por
  `Regex.escape` e cujo match é Unicode (`?` é um caractere, não um byte), então a
  compilação não pode falhar por causa da entrada; um padrão que não é UTF-8 é erro
  de schema (`:not_utf8`) em vez de estourar no meio da comparação. Cada padrão é
  compilado **uma vez por avaliação** e reusado no check de entregue e de
  autorizado — compilar por par path × padrão deixaria um contrato de 256+256
  padrões com um candidato de 5 000 paths passar de milhões de compilações;
- **path traversal**: padrões com `/` inicial, `..` ou `\` são erro de schema; a
  comparação é textual e ancorada, sem resolução de filesystem, e symlinks não
  movem o escopo;
- **symlink**: a leitura dos arquivos não rastreados usa `lstat` e recusa tudo que
  não for arquivo regular (um link não faz a varredura ler fora do workspace);
  **arquivo regular que não pode ser lido** (permissão, corrida, I/O) não é
  "varredura completa": ele conta como buraco no scan (o mesmo
  `prohibition_scan_truncated`), porque pode conter uma proibição que a camada não
  vê — diferente do symlink/diretório/dispositivo, cujo conteúdo não faz parte do
  candidato e cuja recusa é intencional;
- **segredos**: o texto dos findings é mascarado (`gho_*`, `ghp_*`, `github_pat_*`,
  `sk-*`, `x-access-token:`), truncado e sem quebras de linha antes de ir para log
  ou comentário; a saída das evidências não é persistida;
- **injeção em comentário**: `<` é neutralizado no texto humano (mensagem **e** o
  path mostrado na prosa), então uma alteração do candidato não consegue reescrever
  o comentário nem forjar marcação de handoff; o campo `Finding.path` permanece
  literal para o consumidor de máquina;
- **comandos**: só vêm de `delivery.gates`/`delivery.evidence` (configuração do
  projeto). A issue contribui com **nomes** de evidência, nunca com comandos.

## 10. Como o consumidor prepara um issue executável

```yaml
pipeline_contract:
  version: 1
  scope_mode: strict
  expected_paths:
    - docs/changes/<data>-<assunto>.md
    - tests/agent/run-tests.sh
  allowed_extra_paths: []
  required_evidence: [agent-tests, wordpress-tests, repository-gates]
  remote_access: false
  deploy: false
```

e no `WORKFLOW.md` do projeto:

```yaml
delivery:
  gates: "scripts/agent/preflight.sh --gates"
  evidence:
    agent-tests: "tests/agent/run-tests.sh"
    wordpress-tests: "tests/wordpress/run-tests.sh"
```

Enquanto o consumidor não tiver contrato nas issues, nada muda: o aceite reporta
`not_configured` e o handoff segue o ADR-0005.
