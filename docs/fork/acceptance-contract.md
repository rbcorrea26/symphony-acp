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
chave existe só como **dica textual que amplia o conjunto de falhas**: um bloco que
cita a chave mas não pode ser decodificado é erro (`invalid_yaml`), nunca ausência;
e uma âncora estrutural faz o bloco ser recusado **sem** ser parseado (o grafo de
alias nunca é expandido).

## 3. Semântica de escopo

`expected_paths` significa **"o candidato entrega este path"**, não "o path existe
no repositório": a comparação é com o **change set do candidato** (o que será
publicado), obtido de `git status --porcelain -z -uall`. Um arquivo que já existia
na base e não foi tocado **não satisfaz** o contrato — foi exatamente o caso #64.

A leitura do change set **falha fechada**: acima de 5 000 entradas é erro
(`change_set_too_large`) e um path que não é UTF-8 válido é recusado
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
| paths entregues/autorizados | **sim, determinístico** | change set do git (`--porcelain -z -uall`) |
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
limite residual declarado: a captura de `git status`/`git ls-files` é proporcional ao
número de paths do candidato (o change set é limitado a 5 000 entradas); o *parse* e
as estruturas construídas aqui são limitados.

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
| sem change set novo (`--resume-only`, nada a publicar) | `:not_applicable` | nenhum (o candidato publicado foi aceito quando foi criado) |
| `strict`, sem achados | `:pass` | segue: gates → evidências → publicação |
| `strict`, com achados | `:fail` | run falha **sem publicar** (nada de branch/PR/rótulo/comentário) |
| `strict`, varredura de proibição **truncada** | `:fail` (`prohibition_scan_truncated`) | run falha sem publicar: um scan parcial não certifica ausência de proibição |
| `advisory`, com achados | `:advisory` | publica normalmente; achados no log e no comentário |
| contrato inválido | `:fail` (`mode: nil`) | run falha sem publicar (`invalid_contract`) |

Idempotência: o veredicto é função de (contrato, change set, comandos de
evidência), então repetir o aceite sobre o mesmo candidato dá o mesmo resultado; um
retry não publica nada em caso de falha e não duplica o comentário em caso de
sucesso (o comentário é chaveado pelo SHA do candidato).

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
<!-- acceptance:result:<candidate-sha> -->
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
limite de tamanho. O comentário é escrito **antes** dos rótulos de promoção, para que
uma falha de escrita não deixe a issue promovida sem o veredicto. Limite declarado:
quando o aceite **reprova**, o run falha e **não** publica nem comenta (a evidência
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
  falha, nunca declarar ausência;
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
