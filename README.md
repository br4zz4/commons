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
| `<m>.lint` `<m>.audit` `<m>.test` `<m>.build` | `<code>/ci/checks/<step>.sh`, the same hook the pipeline runs |
| `<m>.validate` `<m>.plan` | `<infra>/ci/checks/<step>.sh` |
| `<m>.<name>` | `<code>/run/<name>` |
| `<m>.shell` `<m>.db` `<m>.keys` | shell, `psql "$DATABASE_URL"`, key names of the scope |
| `<m>.remote` `<m>.secrets` | `<infra>/ops/remote.sh`, secret push through `<infra>/ops/secrets.sh` |
| `up` `down` `logs` | compose services |
| `conform` `github.setup` `commons.update` `help` | project checks and maintenance |

Every command takes `ENV=`, `ARGS=` and, for restricted environments, `CONFIRM=<project>`.

## Compose

```yaml
include:
  - .commons/compose/database.yml
  - .commons/compose/mail.yml
```

The database reads `DATABASE_PORT`, `DATABASE_USERNAME` and `DATABASE_PASSWORD` from `.env` and fails when any is missing (the server listens on `DATABASE_PORT` too, so host and container share one port). `cache.yml` and `mail.yml` work the same way: `CACHE_PORT`, `MAIL_PORT` and `SMTP_PORT` come from `.env`, have no default and fail when missing.

There is no Redis by default: Rails projects use Solid Cache and Solid Queue on Postgres. `cache.yml` is opt-in: declare `redis` in the module `services` of `.github/modules.json` (or include `.commons/compose/cache.yml` by hand, port `COMMONS_CACHE_PORT`) and record the exception in an ADR.

## Example

`examples/polyglot` has a ruby, a go and an elixir module with the same hooks; the CI of this
repo runs `make <m>.lint` and `make <m>.test` on each.
