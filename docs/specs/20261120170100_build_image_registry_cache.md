---
title: Cache de camadas no registry para o commons build-image
status: proposed
created: 2026-11-20
updated: 2026-11-20
owner: "@oporpino"
certainty: high
---

# Cache de camadas no registry para o commons build-image

> **TLDR**: `commons build-image` ganha `--cache-ref <ref>`. Com ele, o build roda num builder buildx `docker-container`, lê e grava o cache de camadas no registry (`type=registry`, `mode=max`) e empurra a imagem direto (`--push`), sem `docker push` separado. Sem a flag, o comando continua idêntico ao de hoje.

Parte da spec coordenadora `brazza.tech/lunetamagica/docs/specs/20261120170000_ci_time_optimization.md`.

# what

Como dev Brazza, quero que o build de release no CI reaproveite as camadas do build anterior guardadas no próprio registry, para que o tempo entre o merge e o staging não pague apt, ferramentas e `bundle install` a cada release.

## out of scope

- Cache no disco persistente do Blacksmith (`useblacksmith/setup-docker-builder`). É o plano B se a medição no luneta decepcionar, numa spec própria.
- `RUN --mount=type=cache` no `Dockerfile.tmpl`: o cache em registry não guarda o conteúdo dessas montagens, então não haveria ganho.
- Imagem base pré-publicada (`base` + `tools`).
- Mudanças no alvo `dev` e no fluxo local (`compose`, `run/shell`).
- Builds multi-arch.

## acceptance criteria

```gherkin
Cenário: build com cache no registry
  Dado um módulo com .module/build.env válido
  Quando rodo `commons build-image core release --tag R/web:T --push --cache-ref R/web:buildcache`
  Então o comando executado é `docker buildx build` com o builder `commons`
  E inclui `--cache-from type=registry,ref=R/web:buildcache`
  E inclui `--cache-to type=registry,ref=R/web:buildcache,mode=max,image-manifest=true,oci-mediatypes=true`
  E inclui `--push` e `-t R/web:T`

Cenário: builder criado sob demanda
  Dado que `docker buildx inspect commons` falha
  Quando rodo build-image com `--cache-ref`
  Então roda `docker buildx create --name commons --driver docker-container` antes do build

Cenário: builder existente é reaproveitado
  Dado que `docker buildx inspect commons` tem sucesso
  Quando rodo build-image com `--cache-ref`
  Então não roda `docker buildx create`

Cenário alternativo: cache sem push
  Quando rodo build-image com `--cache-ref` e sem `--push`
  Então o comando falha com "--cache-ref exige --push"
  E nenhum `docker build` é executado

Cenário alternativo: cache-ref sem valor
  Quando rodo build-image com `--cache-ref` sem argumento
  Então o comando falha com "--cache-ref exige valor"

Cenário: sem cache-ref nada muda
  Quando rodo `commons build-image core dev` em macOS ou Linux
  Então o comando executado é o mesmo `docker build ... --target dev` de hoje, sem buildx create nem cache

Cenário: primeiro build com o ref de cache ainda inexistente
  Dado que R/web:buildcache não existe no registry
  Quando rodo build-image com `--cache-ref R/web:buildcache --push`
  Então o build conclui e o ref de cache passa a existir
```

# why

- No luneta, o job `core / build` leva cerca de 150 s e o log não tem nenhuma linha `CACHED`. O runner é efêmero, então toda camada é refeita: apt da `base` (12 s), `tools` (7 s), `bundle install` (34 s). Como os hashes mudam a cada build, o push sobe tudo de novo (cerca de 26 s).
- Com o cache no registry, o BuildKit só baixa as camadas que vai usar e só sobe blobs que ainda não existem. A estimativa é de 5 a 10 s de download contra cerca de 70 s economizados.
- O lugar certo é o commons: todo projeto que usa `build-image` ganha o mesmo comportamento sem copiar flags de buildx.

# how

Sem feature flag: mudança aditiva, invisível até alguém passar `--cache-ref`.

Sem telas.

## PR 1 — `build-image --cache-ref` (branch: `feat/build-image-cache-1`, base: `main`)

**Entrega:** a flag `--cache-ref`, o builder sob demanda, a documentação e os testes.

### Task 1: testes (tester)
**Arquivos:** Modify `tests/run.sh` (o `fakebin/docker` registra os argumentos; `docker buildx inspect commons` é controlado por uma variável do fake)
**Passos:** um teste por cenário acima, todos vermelhos → commit `test: build-image registry cache`
**Valida:** `sh tests/run.sh` (falham só os novos testes)

### Task 2: parser e builder
**Arquivos:** Modify `lib/image.sh`, `bin/commons` (texto do help na linha do `build-image`)
**Passos:**
- `commons_image_build` aceita `--cache-ref <ref>`; sem valor → `commons_die "--cache-ref exige valor"`; com `cache_ref` e sem `push` → `commons_die "--cache-ref exige --push"`.
- Com `cache_ref`: `docker buildx inspect commons >/dev/null 2>&1 || docker buildx create --name commons --driver docker-container >/dev/null`; o comando vira `docker buildx build --builder commons` com os mesmos `--build-context`, `--build-arg`, `--target`, `-f`, `-t`, `--platform`, mais `--cache-from type=registry,ref=$cache_ref`, `--cache-to type=registry,ref=$cache_ref,mode=max,image-manifest=true,oci-mediatypes=true` e `--push`.
- Sem `cache_ref`: o comando atual, sem nenhuma mudança.
- Help: `build-image <m> <dev|release>  build the module image [--tag T] [--platform P] [--push] [--cache-ref R]`.

Testes da Task 1 verdes → commit `feat: build-image registry cache`
**Valida:** `sh tests/run.sh`

### Task 3: documentação
**Arquivos:** Modify `README.md` (seção do `build-image`: o que `--cache-ref` faz, a exigência de `--push`, o builder `commons` e um exemplo de CI)
**Passos:** commit `docs: build-image cache-ref`
**Valida:** `grep -n -- '--cache-ref' README.md`

**Pronto para prod:** nenhum consumidor passa `--cache-ref` ainda; o comportamento sem a flag é o mesmo.
**Valida (PR):** `sh tests/run.sh` verde e o workflow `self` verde em Linux e macOS.

## SEQUENCE
1. #<pr1> — build-image --cache-ref
Merge in this order: #<pr1>

Depois do merge, o luneta faz o bump do submódulo `.commons` (PR 3 da spec coordenadora).

# definition of done

- [ ] Todo cenário de "acceptance criteria" validado por teste em `tests/run.sh`
- [ ] Cenário "build com cache no registry": teste verifica o comando completo com `--cache-from`, `--cache-to`, `--push` e o builder
- [ ] Cenários "builder criado sob demanda" e "builder existente é reaproveitado": testes verdes
- [ ] Cenários "cache sem push" e "cache-ref sem valor": testes verdes com as mensagens exatas
- [ ] Cenário "sem cache-ref nada muda": teste compara o comando com o de hoje
- [ ] Cenário "primeiro build com o ref de cache ainda inexistente": validado no primeiro build do luneta (run de main com o job `core / build` verde)
- [ ] Testes automáticos passando: `sh tests/run.sh` e workflow `self` (Linux e macOS)
- [ ] Toda task do "how" executada
- [ ] README atualizado com `--cache-ref`
- [ ] Staging: `staging: none` (biblioteca; a validação em staging fica na spec coordenadora do luneta)
- [ ] Banner `FINISHED` impresso como última saída (`br4zz4:finish`, Step 7), só com todos os itens acima marcados

## documentation

- `README.md`: seção do `build-image`.
