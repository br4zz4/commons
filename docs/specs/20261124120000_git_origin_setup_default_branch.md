---
title: git.origin.setup lê a branch default sem `gh repo view -R`
status: proposed
created: 2026-11-24
updated: 2026-11-24
owner: "@oporpino"
certainty: high
---

# git.origin.setup lê a branch default sem `gh repo view -R`

> **TLDR**: `make git.origin.setup` quebra no passo do ruleset porque `lib/github.sh:36` chama `gh repo view -R`, flag que o `gh repo view` não aceita; trocar por `gh api "repos/$repo" --jq .default_branch`, deixar o `gh` falso dos testes estrito para o bug não voltar e corrigir o README.

# what

Como dev Brazza, quero que `make git.origin.setup` termine criando o ruleset `commons-default-branch`, para que a `main` de cada projeto exija `COMMONS_REQUIRED_CHECK` pelo ruleset do commons e não por proteção clássica configurada à mão.

## out of scope

- Mudar o payload do ruleset, as regras de merge ou a escrita de secrets.
- Rodar o alvo nos projetos consumidores (cada projeto faz o bump do `.commons` e roda depois).

## acceptance criteria

    Cenário: ruleset criado com o gh real
      Dado um projeto com COMMONS_REQUIRED_CHECK=check/pr e um workflow na default que declara check/pr
      Quando roda `make git.origin.setup`
      Então a branch default é lida por `gh api repos/<owner>/<repo> --jq .default_branch`
      E o ruleset commons-default-branch é criado ou atualizado sem erro

    Cenário alternativo: regressão para `repo view -R`
      Dado o gh falso dos testes
      Quando o código chama `gh repo view -R ...`
      Então o gh falso sai com erro "unknown shorthand flag: 'R'" e o teste falha

    Cenário: branch default diferente de main
      Dado um repositório cuja default é `trunk`
      Quando roda `make git.origin.setup`
      Então o workflow é procurado em `origin/trunk`

    Cenário: README com o alvo atual
      Quando se lê o README
      Então ele cita `make git.origin.setup` e não `make github.setup`

# why

No `lunetamagica` o `make git.origin.setup` para no passo do ruleset, então a `main` só exige `check/pr` por uma proteção clássica feita à mão e o contrato (`docs/contract.md`, seção `git.origin.setup`) não se cumpre. O `gh repo view` recebe o repositório como argumento posicional; `-R` não é flag dele. A suíte não pegou porque o `gh` falso (`tests/fixtures/fakebin/gh:12`) aceita qualquer coisa depois de `repo view`.

# how

Uma mudança coesa, um PR. Sem feature flag: correção de bug em script de manutenção. Sem telas. `staging: none` (biblioteca).

## PR 1 — Branch default via `gh api` (branch: `fix/git-origin-setup-default-branch`, base: `main`)
**Arquivos:**
- Test `tests/fixtures/fakebin/gh` (tester): `repo view` com `-R` sai com status 1 e `unknown shorthand flag: 'R' in -R` no stderr; novo caso `api repos/<repo> --jq .default_branch` devolve `${GH_DEFAULT_BRANCH-main}`
- Test `tests/run.sh` (tester): `t_gh_default_branch_via_api` (log contém `gh api repos/demo/repo --jq .default_branch` e não contém `repo view -R`) e `t_gh_default_branch_custom` (`GH_DEFAULT_BRANCH=trunk` faz o grep em `origin/trunk`); registrar com `run_case "git.origin.setup: ..."`
- Modify `lib/github.sh:36` → `default=$(gh api "repos/$repo" --jq .default_branch)`
- Modify `README.md:16` e `:48` → `make git.origin.setup`
**Passos:** testes vermelhos → troca na linha 36 → testes verdes → README → commit `fix: read default branch via gh api in git.origin.setup`
**Pronto para prod:** só muda como a branch default é lida; os demais passos ficam iguais.
**Valida:** `sh tests/run.sh` verde (macOS e Linux, `sh` POSIX); `rg -n 'repo view -R' lib bin make` vazio.

Depois do merge, mover a tag `v1` conforme o processo de release do commons, para os projetos receberem a correção no `commons.update`.

# definition of done

- [ ] Todo cenário de "acceptance criteria" foi validado (automatizado ou verificado com comando exato)
- [ ] Testes automáticos passando — suíte verde, não só a parte nova
- [ ] Toda task do "how" executada
- [ ] Documentação atualizada (README)
- [ ] Staging: `staging: none` (biblioteca)
- [ ] `gh` falso falha com `repo view -R` e o teste de regressão fica vermelho sem a correção (cenário "regressão")
- [ ] `t_gh_default_branch_via_api` verde (cenário "ruleset criado")
- [ ] `t_gh_default_branch_custom` verde (cenário "branch default diferente de main")
- [ ] `grep -n 'github.setup' README.md` vazio (cenário "README")
- [ ] Tag `v1` contém o commit da correção

## documentation

- `README.md` (alvo `git.origin.setup`).
