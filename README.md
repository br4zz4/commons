# commons

The frame every project shares: one set of `make` commands, compose fragments and
secret loading for every module. It knows no project, language or provider; each project
tells it what it needs in `commons.ctx`, `.github/modules.json` and the scripts of its own modules.

## Adopt

```sh
git submodule add https://github.com/br4zz4/commons .commons
.commons/bin/init
```

`init` is idempotent and never overwrites: it creates `Makefile` (with
`include .commons/make/main.mk`), `commons.ctx`, `compose.yml` and the `.gitignore` entry, then
runs `make conform` to list what is missing. Fill `commons.ctx`, then run `make github.setup`
once the generated `pr.yml` is on the default branch.

## commons.ctx

```
COMMONS_PROJECT=myproject
COMMONS_ENVS=development,test,staging,production
COMMONS_ENV_LOCAL=development
COMMONS_ENV_CHECK=test
COMMONS_ENV_REMOTE=staging
COMMONS_VAULT=myproject
COMMONS_RESTRICTED_VAULT=myproject::restricted
COMMONS_RESTRICTED_ENVS=production
COMMONS_SCOPE={vault}:secrets.{module}.{side}.{env}
COMMONS_REF=v1
```

Comment out `COMMONS_VAULT` for a project without ward. See `docs/contract.md` for every key.

## Commands

| make | runs |
|---|---|
| `<m>.lint` `<m>.audit` `<m>.test` | `<code>/run/<step>` when it exists (compose container, same script in CI), else `<code>/ci/checks/<step>.sh` |
| `<m>.build` | `<code>/ci/checks/build.sh` |
| `<m>.validate` `<m>.plan` | `<infra>/ci/checks/<step>.sh` |
| `<m>.<name>` | `<code>/run/<name>` |
| `<m>.shell` `<m>.db` `<m>.keys` | shell, `psql "$DATABASE_URL"`, key names of the scope |
| `<m>.remote` `<m>.secrets` | `<infra>/ops/remote.sh`, secret push through `<infra>/ops/secrets.sh` |
| `build-image <m> <dev\|release>` | module image (see Images; run `commons build-image` directly) |
| `up` `down` `logs` | compose services |
| `conform` `github.setup` `commons.update` `help` | project checks and maintenance |

Every command takes `ENV=`, `ARGS=` and, for restricted environments, `CONFIRM=<project>`.

## Images

`commons build-image <module> <dev|release> [--tag T]... [--platform P] [--push] [--cache-ref R]` builds the module image from one generic Dockerfile (`docker/Dockerfile.tmpl`). Without `--tag` the image is `<project>-<module>:<target>`; with `--tag` only the given tags are applied.

`--cache-ref R` (CI) reads and writes the layer cache in the registry (`type=registry,ref=R,mode=max`) and pushes the image straight from the builder, so it requires `--push`. It runs on a `docker-container` buildx builder named `commons`, created on demand. Runners are ephemeral, so this is what lets `base`, `tools` and `deps` come back as `CACHED` when the manifests did not change. Without the flag the command is the plain `docker build`.

Stages: `base` (runtime) → `tools` (compilers) → `deps` (manifests + dependencies) → `dev` (dev tools, `CMD_DEV`) · `source` (code) → `release` (dependencies + code, `release.env`, user, `CMD_RELEASE`). Each stage copies only its own scripts, so editing a `dev` script never invalidates `deps`.

Layout in commons:

```
docker/
  Dockerfile.tmpl
  stacks/<stack>/              ruby, go, elixir
    defaults.env               BASE_IMAGE, CMD_DEV, CMD_RELEASE, EXPOSE, RELEASE_USER, DEPS_PATHS
    manifests                  dependency files, one per line (Gemfile, Gemfile.lock)
    base.env                   KEY=VALUE, becomes ENV after the base stage
    release.env                KEY=VALUE, becomes ENV in the release stage
    <stage>.<NN>.<name>.sh     stage scripts, steps of 10
```

Layout in the module (`<code>/.module/`):

```
build.env                      STACK, STACK_VERSION and overrides of defaults.env
release.env                    optional, extra ENV for release
scripts/<stage>.<NN>.<name>.sh module scripts, `50` by convention
```

Scripts are named `<stage>.<NN>.<name>.sh` with stage in `base|tools|deps|dev|release`. Stack and module scripts are merged by file name (the module wins on equal names) and run in name order with `set -e`; a failure aborts the build and prints the script name. A stage without scripts is fine.

`DEPS_ENV` (`dev` or `release`, the build target) reaches the `deps` scripts; `STACK_VERSION`, `PROJECT` and `RELEASE_USER` reach every stage.

```sh
# <code>/.module/build.env
STACK=ruby
STACK_VERSION=3.4.7

commons build-image core dev
commons build-image core release --platform linux/amd64 --tag registry/app:1.0 --push
commons build-image core release --platform linux/amd64 --tag registry/app:1.0 --push --cache-ref registry/app:buildcache
```

## Compose

```yaml
include:
  - .commons/compose/database.yml
  - .commons/compose/mail.yml
```

The database reads `DATABASE_PORT`, `DATABASE_USERNAME` and `DATABASE_PASSWORD` from `.env` and fails when any is missing (the server listens on `DATABASE_PORT` too, so host and container share one port). `cache.yml` and `mail.yml` work the same way: `CACHE_PORT`, `MAIL_PORT` and `SMTP_PORT` come from `.env`, have no default and fail when missing.

There is no Redis by default: Rails projects use Solid Cache and Solid Queue on Postgres. `cache.yml` is opt-in: declare `redis` in the module `services` of `.github/modules.json` (or include `.commons/compose/cache.yml` by hand, port `COMMONS_CACHE_PORT`) and record the exception in an ADR.

`commons run <module> <script>` runs the script in the module's compose service when `compose.yml` has a service named like the module (profiles included). It builds the dev image (`commons build-image <module> dev`, cached) and runs `docker compose run --rm --service-ports <module> ./run/<script>`, so the service's `depends_on` brings the dependencies up (the compose file owns them; commons never starts services on its own). Only when the resolved environment is `COMMONS_ENV_LOCAL`: with any other `ENV` (for example `make core.console ENV=staging`) the script runs on the host with that scope loaded and `ENVIRONMENT` set, because the dev container knows only the local environment. Without such a service the script runs on the host as before.

`lint`, `audit` and `test` use `<code>/run/<step>` when it exists: in the compose service's container when there is one (as above), and the pipeline runs that same script on the host. Without `run/<step>` they fall back to `<code>/ci/checks/<step>.sh`. `build`, `validate` and `plan` are unchanged.

`commons shell <module>` opens a `zsh` (or `$COMMONS_SHELL`) in that same service after building the dev image, and always exits 0 (the exit status of the last command typed in an interactive shell is not an error). A module `run/shell` overrides it. Only `start` and `server` publish the service ports; every other script runs without them, so two runs never fight over a port.

### Module base service

`compose/module.yml` is a base dev service to extend, so a project only declares what is its own:

```yaml
services:
  core:
    extends: {file: .commons/compose/module.yml, service: module}
    image: <project>-core:dev
    environment:
      WARD_CONTEXT: secrets.core.code.development
    volumes:
      - ./modules/core/code:/source
```

It brings `working_dir`, the root `.env`, `DATABASE_HOST`, `SMTP_HOST`, the ward wiring, the `WEB_PORT` mapping, the read-only vault and `depends_on: database (healthy)`. Relative paths resolve against `.commons/compose/`, so it expects the commons at `.commons/` in the project root.

### Build-time placeholders

`<code>/.module/precompile.env` (`KEY=VALUE`, `#` and blank lines ignored) holds the variables `assets:precompile` needs when the release image is built without runtime secrets. It reaches only the release stage, so editing it never invalidates the dependency layer.

## Example

`examples/polyglot` has a ruby, a go and an elixir module with the same hooks; the CI of this
repo runs `make <m>.lint` and `make <m>.test` on each.
