# Sincronização com o upstream (`openai/symphony`)

Objetivo: manter o fork atualizado sem perder suas alterações e sem esconder
divergências. `main` integra upstream e trabalho próprio; `upstream/main` é a
referência original, somente leitura. ACP ainda não foi implementado.

## 1. Antes de começar

Confirme que o worktree está limpo e que os remotes apontam para os repositórios
esperados. Se houver alterações locais, preserve-as antes de continuar.

```bash
git remote -v
git status --short
git fetch origin
git fetch upstream
git log --oneline origin/main..upstream/main
git diff --stat upstream/main...origin/main
```

## 2. Decidir o que entra

- Sincronize em branch dedicada criada a partir de `origin/main`, que já contém
  as alterações do fork. Integre `upstream/main` por merge, preservando os dois
  históricos. Não recrie a branch a partir do upstream nem faça rebase publicado.
- Se o upstream já for ancestral de `origin/main`, não há atualização a integrar.
- Tags/releases upstream não são republicadas; releases próprias têm versão
  própria. Um SHA de `main` não é automaticamente o SHA da última release.

## 3. Sequência recomendada

Substitua `sync/upstream-AAAA-MM-DD` por um nome de branch ainda não usado.

```bash
# 1) partir da versão integrada do fork
git switch -c sync/upstream-AAAA-MM-DD origin/main
git merge --no-ff upstream/main
# Em caso de conflito: resolver preservando os comportamentos, revisar e commitar.
# Para desistir de um merge em conflito: git merge --abort.

# 2) validar e revisar o resultado
make -C elixir all
(cd elixir && mix specs.check)
git diff --check origin/main...HEAD
git diff --stat upstream/main HEAD

# 3) atualizar docs/fork/divergences.md e a base registrada em docs/fork/README.md
#    e commitar esses ajustes separadamente do merge upstream

# 4) publicar somente no fork e abrir PR com o template do repositório
git push -u origin HEAD
gh pr create --repo rbcorrea26/symphony-acp --base main
```

Antes da integração, valide o corpo com `mix pr_body.check --file /path/to/pr_body.md`
em `elixir/`, confira CI, diff, conflitos e o registro de divergências. Integre a
PR por **merge commit**, preservando a ancestralidade upstream, sem bypass de gates.
Depois, atualize o clone local com `git switch main` e `git pull --ff-only origin main`.
Na plataforma, registre separadamente `symphony-base` (SHA upstream incorporado) e
`symphony-fork` (SHA integrado do fork) em `manifests/tool-versions.txt`.

## 4. Regras

- **Nunca** faça push para `upstream`, incluindo branches e tags; não altere sua
  configuração durante a sincronização.
- **Nunca** use force-push ou reescreva o histórico publicado do fork.
- Não misture sincronização e implementação de extensões no mesmo PR.
- Em conflitos, preserve o comportamento upstream e registre a resolução.
  Mudança arquitetural exige ADR no repositório responsável pela decisão.
- O diff final deve conter somente divergências justificadas no registro:
  documentação do fork, aviso no README, AGENTS e, quando implementadas,
  extensões com seus testes e documentação necessários.

## 5. Sinal de alerta

Se o diff crescer sem que [divergences.md](divergences.md) cresça junto, pare e
justifique cada arquivo antes de continuar. O código upstream não alterado
continua autoritativo; a preservação do caminho Codex é obrigatória.
