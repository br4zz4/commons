# Contract

What a project provides for `br4zz4/commons` and what the commons guarantees in return.

## Files of a project

```
.commons/                           submodule of br4zz4/commons, pinned at COMMONS_REF
commons.ctx                         the only place that names the project, environments and vaults
.github/modules.json                module registry (same file the pipelines read)
Makefile                            include .commons/make/main.mk
compose.yml                         include of .commons/compose/*.yml
modules/<m>/code/mise.toml          toolchain, required by every command that runs a script
modules/<m>/code/ci/checks/*.sh     hooks (lint audit test build)
modules/<m>/code/run/<name>         local commands, one make target each
modules/<m>/infra/ci/checks/*.sh    hooks (validate plan)
modules/<m>/infra/ops/{remote,secrets}.sh   ops hooks, optional
```

## commons.ctx

`KEY=value`, no quotes, no spaces. Make includes it and sh sources it.

| key | required | meaning |
|---|---|---|
| `COMMONS_PROJECT` | yes | project name; text of the confirmation and `COMPOSE_PROJECT_NAME` |
| `COMMONS_ENVS` | yes | valid environments, comma separated |
| `COMMONS_ENV_LOCAL` | yes | default of `run/*`, `shell` and `db` |
| `COMMONS_ENV_CHECK` | yes | default of `lint`, `audit`, `test` and `validate` |
| `COMMONS_ENV_REMOTE` | yes | default of `build`, `plan`, `remote`, `secrets` and `keys` |
| `COMMONS_VAULT` | no | ward vault; empty or commented means no ward |
| `COMMONS_SCOPE` | with vault | template with `{vault}`, `{module}`, `{side}`, `{env}` |
| `COMMONS_RESTRICTED_VAULT` | no | vault of the restricted environments |
| `COMMONS_RESTRICTED_ENVS` | with restricted vault | environments that ask for confirmation |
| `COMMONS_GITHUB_SECRETS` | no | `NAME:key-file` pairs written by `github.setup` |
| `COMMONS_REQUIRED_CHECK` | no | status check required by the default-branch ruleset |
| `COMMONS_REF` | yes | tag used by `commons.update` |

A missing required key fails with `commons: commons.ctx sem <KEY>`; an environment outside
`COMMONS_ENVS` fails with `commons: ambiente <x> fora de COMMONS_ENVS`.

## Resolution

1. Environment: `ENV` > `ENVIRONMENT` > the default of the command. `ENV` is unset before any child runs.
2. Vault: the restricted one for `COMMONS_RESTRICTED_ENVS`, otherwise `COMMONS_VAULT`.
3. Scope: `COMMONS_SCOPE` filled with the four placeholders.
4. Load: `ward exec <scope> -- ...`; a missing key fails, an empty scope warns and goes on.
   The code-side scope also becomes `WARD_CONTEXT` (the scope without the vault prefix, e.g. `secrets.core.code.staging`) unless the caller already set it, so the app knows which scope it runs in.
5. Guard: a restricted environment asks for `COMMONS_PROJECT` on a TTY, requires `CONFIRM=<project>` without one, and skips the question when `GITHUB_ACTIONS=true`.
6. Toolchain: every script runs under `mise exec -C <dir>`; a directory without `mise.toml` fails.
7. Parity with the pipeline: cwd is the side directory, with `MODULE`, `ENVIRONMENT`, `TAG` and `CI_CACHE_DIR=<dir>/.ci-cache`.

## Ops hooks

| hook | contract |
|---|---|
| `remote.sh` | opens a shell or runs `$@` in the remote environment, with the scopes loaded |
| `secrets.sh` | writes every key of `COMMONS_SECRET_KEYS` to the provider's secret store |

`secrets` fails listing only the names of keys that are empty or `CHANGE_ME`, before running the hook.
A key present in both the code and infra scope fails `remote` and `secrets`.

## conform

Fails, citing the file, when: `commons.ctx` is missing a key or names an unknown environment;
`modules.json` is missing, invalid or has a bad module name; `run/` holds a reserved name
(`lint audit test build validate plan shell db keys remote secrets`); `ops/` holds anything but
`remote.sh` and `secrets.sh`; `compose.yml` includes a fragment that does not exist.

## github.setup

Idempotent. Writes the secrets of `COMMONS_GITHUB_SECRETS`, allows only squash and rebase merges
with branch deletion, and creates or updates the ruleset `commons-default-branch` requiring
`COMMONS_REQUIRED_CHECK` (GitHub Actions integration, strict). The ruleset waits until a workflow on the
default branch declares that check.
