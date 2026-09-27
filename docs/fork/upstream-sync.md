# Sincronização com o upstream (`openai/symphony`)

Objetivo: manter o fork atualizado sem perder as extensões ACP e sem esconder
divergências. Este procedimento é a fonte da verdade para sincronizar o fork.

## 1. Antes de começar

```bash
git remote -v                     # origin = fork, upstream = openai/symphony
git status --short                # worktree limpo
git fetch --prune upstream
git log --oneline HEAD..upstream/main | head   # o que vem
git diff --stat upstream/main...HEAD           # o que é nosso
```

## 2. Decidir o que entra

- **Fast-forward quando não há divergência:** `main` do fork deve poder avançar
  para `upstream/main` sem merge commit.
- **Com trabalho nosso:** rebase (preferido) ou merge explícito, sempre em branch
  dedicada — nunca reescrevendo commits do upstream.
- **Tags/releases do upstream:** não são republicadas pelo fork; releases do fork
  têm versão própria quando existirem.

## 3. Sequência recomendada

```bash
# 1) main do fork em dia com o upstream (sem commits nossos)
git switch main
git merge --ff-only upstream/main

# 2) branch de trabalho a partir do novo main
git switch -c feat/<assunto>
git rebase main            # reorganiza nossos commits sobre o novo upstream

# 3) gates do upstream (valem para o fork)
cd elixir && make all
cd .. && git diff --stat upstream/main...HEAD   # confira que o diff continua mínimo

# 4) registro
#    - atualizar docs/fork/divergences.md se algo mudou de natureza
#    - registrar o novo SHA base em
#      agentic-dev-environment/manifests/tool-versions.txt (chave symphony-fork)
```

## 4. Regras

- **Nunca** `git push upstream` (incluindo `--tags`). O remote `upstream` é de
  leitura.
- **Nunca** `git push --force` em `main` do fork; force-push só em branch de
  trabalho, se o PR ainda não tiver revisão.
- Sincronização não é misturada com trabalho do fork no mesmo commit.
- Conflito em arquivo upstream: **preserve o comportamento upstream** e registre
  a decisão — se o comportamento do fork precisar mudar, isso é decisão de
  arquitetura e vai para ADR (aqui, se for específico de Symphony/ACP; na
  plataforma, se for decisão do pipeline).
- Depois da sincronização, `git diff --stat upstream/main...HEAD` deve listar
  apenas: `docs/fork/**`, o ponteiro do fork em `README.md`, `AGENTS.md` e os
  arquivos de código das extensões ACP.

## 5. Sinal de alerta

Se o diff contra o upstream começar a crescer sem que
[divergences.md](divergences.md) cresça junto, o fork está divergindo por
acidente — pare, reduza o diff ou justifique cada arquivo antes de continuar.
