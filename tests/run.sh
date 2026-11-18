#!/bin/sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
BIN="$REPO/bin/commons"
MODPY="$REPO/lib/modules.py"
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT INT TERM
ORIG_PATH="$PATH"

unset ENV ENVIRONMENT CONFIRM GITHUB_ACTIONS TAG FAKE_WARD_EMPTY FAKE_WARD_NOKEY FAKE_WARD_NOSCOPE FAKE_WARD_AIMODE

N=0
PASSED=0
FAILED=0
CASE_OK=1
RC=0

setup() {
  N=$((N + 1))
  C="$TMP/case$N"
  mkdir -p "$C"
  cp -R "$HERE/fixtures/project" "$C/project"
  cp -R "$HERE/fixtures/fakebin" "$C/fakebin"
  P="$C/project"
  chmod +x "$C"/fakebin/*
  find "$P" \( -path '*/ci/checks/*.sh' -o -path '*/run/*' \) -type f -exec chmod +x {} +
  ln -s "$REPO" "$P/.commons"
  HOOK_OUT="$C/hook.out"
  FAKE_LOG="$C/fake.log"
  : >"$FAKE_LOG"
  PATH="$C/fakebin:$ORIG_PATH"
  export HOOK_OUT FAKE_LOG PATH
}

cm() {
  ( cd "$P" && env "$@" ) </dev/null >"$C/out" 2>"$C/err"
  RC=$?
}

diag() {
  CASE_OK=0
  printf '# %s\n' "$*"
}

rc_ok() {
  [ "$RC" -eq 0 ] || diag "esperava exit 0, veio $RC; stderr: $(tr '\n' '|' <"$C/err")"
}

rc_fail() {
  [ "$RC" -ne 0 ] || diag "esperava exit != 0, veio 0"
}

err_has() {
  grep -qF -- "$1" "$C/err" || diag "stderr sem '$1'; stderr: $(tr '\n' '|' <"$C/err")"
}

out_has() {
  grep -qxF -- "$1" "$C/out" || diag "stdout sem a linha '$1'; stdout: $(tr '\n' '|' <"$C/out")"
}

hook_has() {
  grep -qxF -- "$1" "$HOOK_OUT" 2>/dev/null || diag "hook sem a linha '$1'; hook: $(tr '\n' '|' <"$HOOK_OUT" 2>/dev/null)"
}

hook_ran() {
  [ -e "$HOOK_OUT" ] || diag "hook não rodou"
}

hook_not_ran() {
  [ ! -e "$HOOK_OUT" ] || diag "hook rodou e não devia"
}

log_has() {
  grep -qF -- "$1" "$FAKE_LOG" || diag "log sem '$1'; log: $(tr '\n' '|' <"$FAKE_LOG")"
}

log_lacks() {
  ! grep -qF -- "$1" "$FAKE_LOG" || diag "log tem '$1' e não devia; log: $(tr '\n' '|' <"$FAKE_LOG")"
}

never_leaks() {
  if cat "$C/out" "$C/err" | grep -q sekret; then
    diag "valor de secret vazou na saída"
  fi
}

ctx_without() {
  grep -v "^$1=" "$P/commons.ctx" >"$P/commons.ctx.new" && mv "$P/commons.ctx.new" "$P/commons.ctx"
}

phys() {
  ( cd "$1" && pwd -P )
}

run_case() {
  name="$1"
  fn="$2"
  setup
  CASE_OK=1
  "$fn"
  if [ "$CASE_OK" -eq 1 ]; then
    PASSED=$((PASSED + 1))
    printf 'ok - %s\n' "$name"
  else
    FAILED=$((FAILED + 1))
    printf 'not ok - %s\n' "$name"
  fi
}

t_hook_code() {
  # arrange
  code="$P/modules/core/code"
  # act
  cm "$BIN" hook core test
  # assert
  rc_ok
  hook_has "MODULE=core"
  hook_has "ENVIRONMENT=check"
  hook_has "CI_CACHE_DIR=$code/.ci-cache"
  hook_has "PWD=$(phys "$code")"
  hook_has "TAG="
  log_has "ward exec demo:secrets.core.code.check"
}

t_hook_steps_code() {
  # arrange
  code="$P/modules/core/code"
  # act
  cm "$BIN" hook core lint
  rc_ok
  hook_has "PWD=$(phys "$code")"
  rm -f "$HOOK_OUT"
  cm "$BIN" hook core audit
  rc_ok
  hook_has "PWD=$(phys "$code")"
  rm -f "$HOOK_OUT"
  cm "$BIN" hook core build
  # assert
  rc_ok
  hook_has "PWD=$(phys "$code")"
  hook_has "ENVIRONMENT=remote"
}

t_hook_infra() {
  # arrange
  infra="$P/modules/core/infra"
  # act
  cm "$BIN" hook core validate
  # assert
  rc_ok
  hook_has "PWD=$(phys "$infra")"
  hook_has "CI_CACHE_DIR=$infra/.ci-cache"
  hook_has "ENVIRONMENT=check"
  log_has "demo:secrets.core.infra.check"
  log_lacks "secrets.core.code"
}

t_hook_infra_plan_remote() {
  # arrange
  infra="$P/modules/core/infra"
  # act
  cm "$BIN" hook core plan
  # assert
  rc_ok
  hook_has "PWD=$(phys "$infra")"
  hook_has "ENVIRONMENT=remote"
  log_has "demo:secrets.core.infra.remote"
}

t_env_remote() {
  # arrange
  # act
  cm ENV=remote "$BIN" hook core test
  # assert
  rc_ok
  hook_has "ENVIRONMENT=remote"
  log_has "demo:secrets.core.code.remote"
}

t_env_over_environment() {
  # arrange
  # act
  cm ENV=remote ENVIRONMENT=dev "$BIN" hook core test
  # assert
  rc_ok
  hook_has "ENVIRONMENT=remote"
}

t_environment_over_default() {
  # arrange
  # act
  cm ENVIRONMENT=dev "$BIN" hook core test
  # assert
  rc_ok
  hook_has "ENVIRONMENT=dev"
  log_has "demo:secrets.core.code.dev"
}

t_default_env() {
  # arrange
  # act
  cm "$BIN" hook core test
  # assert
  rc_ok
  hook_has "ENVIRONMENT=check"
}

t_env_not_leaked() {
  # arrange
  # act
  cm ENV=remote "$BIN" hook core test
  # assert
  rc_ok
  hook_has "ENV=unset"
}

t_shell_env_not_leaked() {
  # arrange
  code="$P/modules/core/code"
  # act
  cm ENV=remote SHELL="$C/fakebin/recshell" "$BIN" shell core
  # assert
  rc_ok
  hook_has "ENV=unset"
  hook_has "PWD=$(phys "$code")"
  log_has "demo:secrets.core.code.remote"
}

t_missing_key() {
  # arrange
  ctx_without COMMONS_ENV_LOCAL
  # act
  cm make --no-print-directory core.shell
  # assert
  rc_fail
  err_has "commons: commons.ctx sem COMMONS_ENV_LOCAL"
  hook_not_ran
}

t_missing_key_direct() {
  # arrange
  ctx_without COMMONS_ENV_LOCAL
  # act
  cm "$BIN" hook core test
  # assert
  rc_fail
  err_has "commons: commons.ctx sem COMMONS_ENV_LOCAL"
  hook_not_ran
}

t_env_invalid() {
  # arrange
  # act
  cm make --no-print-directory core.test ENV=zzz
  # assert
  rc_fail
  err_has "commons: ambiente zzz fora de COMMONS_ENVS"
  hook_not_ran
}

t_ctx_env_outside_envs() {
  # arrange
  ctx_without COMMONS_ENV_CHECK
  printf 'COMMONS_ENV_CHECK=zzz\n' >>"$P/commons.ctx"
  # act
  cm "$BIN" hook core test
  # assert
  rc_fail
  err_has "commons: ambiente zzz fora de COMMONS_ENVS"
  hook_not_ran
}

t_no_ward() {
  # arrange
  ctx_without COMMONS_VAULT
  ctx_without COMMONS_RESTRICTED_VAULT
  ctx_without COMMONS_RESTRICTED_ENVS
  printf '# COMMONS_VAULT=x\n' >>"$P/commons.ctx"
  # act
  cm "$BIN" hook core test
  # assert
  rc_ok
  hook_has "MODULE=core"
  log_lacks "ward"
}

t_empty_scope() {
  # arrange
  # act
  cm FAKE_WARD_EMPTY=1 "$BIN" hook core test
  # assert
  rc_ok
  err_has "commons: escopo demo:secrets.core.code.check vazio"
  hook_ran
  log_lacks "ward exec"
}

t_noscope_hook_warns() {
  # arrange
  # act
  cm FAKE_WARD_NOSCOPE=1 "$BIN" hook core lint
  # assert
  rc_ok
  err_has "commons: escopo "
  err_has " vazio"
  if grep -q "sem acesso ao vault" "$C/err"; then diag "tratou escopo ausente como falta de chave"; fi
  hook_ran
  log_lacks "ward exec"
}

t_noscope_keys_fails() {
  # arrange
  # act
  cm FAKE_WARD_NOSCOPE=1 "$BIN" keys core
  # assert
  rc_fail
  err_has "commons: escopo demo:secrets.core.code.remote vazio"
  if grep -q "sem acesso ao vault" "$C/err"; then diag "tratou escopo ausente como falta de chave"; fi
}

t_noscope_secrets_fails() {
  # arrange
  # act
  cm FAKE_WARD_NOSCOPE=1 "$BIN" secrets core
  # assert
  rc_fail
  err_has "commons: escopo demo:secrets.core.code.remote vazio"
  if grep -q "sem acesso ao vault" "$C/err"; then diag "tratou escopo ausente como falta de chave"; fi
  hook_not_ran
}

t_no_restricted_key() {
  # arrange
  # act
  cm ENV=prod CONFIRM=demo FAKE_WARD_NOKEY=1 "$BIN" hook core test
  # assert
  rc_fail
  err_has "commons: sem acesso ao vault demo::restricted (falta a chave)"
  hook_not_ran
}

t_guard_without_confirm() {
  # arrange
  # act
  cm ENV=prod "$BIN" hook core test
  # assert
  rc_fail
  hook_not_ran
  log_lacks "ward exec"
}

t_guard_wrong_confirm() {
  # arrange
  # act
  cm ENV=prod CONFIRM=other "$BIN" hook core test
  # assert
  rc_fail
  hook_not_ran
}

t_guard_confirm() {
  # arrange
  # act
  cm ENV=prod CONFIRM=demo "$BIN" hook core test
  # assert
  rc_ok
  hook_has "ENVIRONMENT=prod"
  log_has "ward exec demo::restricted:secrets.core.code.prod"
}

t_guard_github_actions() {
  # arrange
  # act
  cm ENV=prod GITHUB_ACTIONS=true "$BIN" hook core test
  # assert
  rc_ok
  hook_has "ENVIRONMENT=prod"
  log_has "demo::restricted:secrets.core.code.prod"
}

t_guard_via_environment() {
  # arrange
  # act
  cm ENVIRONMENT=prod "$BIN" hook core test
  # assert
  rc_fail
  hook_not_ran
}

t_default_vault_outside_restricted() {
  # arrange
  # act
  cm ENV=remote "$BIN" hook core test
  # assert
  rc_ok
  log_has "ward exec demo:secrets.core.code.remote"
  log_lacks "restricted"
}

t_no_mise_toml() {
  # arrange
  rm "$P/modules/core/code/mise.toml"
  # act
  cm "$BIN" hook core test
  # assert
  rc_fail
  err_has "commons: $P/modules/core/code sem mise.toml"
  hook_not_ran
}

t_step_outside_vocabulary() {
  # arrange
  # act
  cm "$BIN" hook core deploy
  # assert
  rc_fail
  hook_not_ran
}

t_step_console_not_a_hook() {
  # arrange
  # act
  cm "$BIN" hook core console
  # assert
  rc_fail
  hook_not_ran
}

t_script_not_executable() {
  # arrange
  chmod -x "$P/modules/core/code/ci/checks/test.sh"
  # act
  cm "$BIN" hook core test
  # assert
  [ ! -x "$P/modules/core/code/ci/checks/test.sh" ] || diag "script ainda executável"
  rc_ok
  hook_has "MODULE=core"
}

t_keys_names_only() {
  # arrange
  # act
  cm "$BIN" keys core
  # assert
  rc_ok
  out_has "A"
  out_has "B"
  [ "$(wc -l <"$C/out" | tr -d ' ')" = "2" ] || diag "esperava 2 linhas, veio: $(tr '\n' '|' <"$C/out")"
  never_leaks
  log_has "demo:secrets.core.code.remote"
}

t_keys_via_make() {
  # arrange
  # act
  cm make --no-print-directory core.keys
  # assert
  rc_ok
  out_has "A"
  out_has "B"
  never_leaks
}

t_keys_empty_scope_fails() {
  # arrange
  # act
  cm FAKE_WARD_EMPTY=1 "$BIN" keys core
  # assert
  rc_fail
  err_has "commons: escopo demo:secrets.core.code.remote vazio"
}

t_keys_no_key_fails() {
  # arrange
  # act
  cm FAKE_WARD_NOKEY=1 "$BIN" keys core
  # assert
  rc_fail
  err_has "commons: sem acesso ao vault demo (falta a chave)"
  never_leaks
}

t_keys_clean_names() {
  # arrange
  # act
  cm "$BIN" keys core
  # assert
  rc_ok
  if grep -q "$(printf '\033')" "$C/out"; then diag "stdout com ANSI"; fi
  if grep -qiE 'active|overrides|=' "$C/out"; then diag "stdout com legenda ou valor"; fi
  [ "$(sort "$C/out" | tr '\n' ' ')" = "A B " ] || diag "stdout inesperado: $(tr '\n' '|' <"$C/out")"
  never_leaks
}

t_secrets_value_with_equals_and_spaces() {
  # arrange
  # act
  cm "FAKE_WARD_PAIRS=A=sekret x=y z\nB=" "$BIN" secrets core
  # assert
  rc_fail
  err_has "commons: sem valor: B"
  hook_not_ran
  never_leaks
}

t_secrets_equals_value_ok() {
  # arrange
  # act
  cm "FAKE_WARD_PAIRS=A=sekret1=x y\nB=sekret2 = z" "$BIN" secrets core
  # assert
  rc_ok
  hook_has "ENVIRONMENT=remote"
  never_leaks
}

t_keys_restricted_guard() {
  # arrange
  # act
  cm ENV=prod "$BIN" keys core
  # assert
  rc_fail
  never_leaks
}

t_run_args() {
  # arrange
  code="$P/modules/core/code"
  # act
  cm "$BIN" run core console one two
  # assert
  rc_ok
  hook_has "ARGS=one two"
  hook_has "MODULE=core"
  hook_has "ENVIRONMENT=dev"
  hook_has "PWD=$(phys "$code")"
  hook_has "CI_CACHE_DIR=$code/.ci-cache"
  log_has "demo:secrets.core.code.dev"
}

t_run_env_remote() {
  # arrange
  # act
  cm ENV=remote "$BIN" run core console
  # assert
  rc_ok
  hook_has "ENVIRONMENT=remote"
  hook_has "ENV=unset"
  log_has "demo:secrets.core.code.remote"
}

t_run_restricted_guard() {
  # arrange
  # act
  cm ENV=prod "$BIN" run core console
  # assert
  rc_fail
  hook_not_ran
}

t_run_missing_script() {
  # arrange
  # act
  cm "$BIN" run core nope
  # assert
  rc_fail
  hook_not_ran
}

t_unknown_module() {
  # arrange
  # act
  cm "$BIN" hook nope test
  # assert
  rc_fail
  err_has "commons: módulo nope desconhecido"
  hook_not_ran
}

t_invalid_module_name() {
  # arrange
  # act
  cm "$BIN" hook Bad-Name test
  # assert
  rc_fail
  hook_not_ran
}

t_invalid_name_in_modules_json() {
  # arrange
  printf '{"modules":{"Bad-Name":{},"core":{}}}\n' >"$P/.github/modules.json"
  # act
  cm "$BIN" hook core test
  # assert
  rc_fail
  err_has "fora de [a-z][a-z0-9_]*"
  hook_not_ran
}

t_py_list() {
  # arrange
  # act
  cm python3 -I "$MODPY" "$P" list
  # assert
  rc_ok
  [ "$(tr '\n' ' ' <"$C/out")" = "core plain " ] || diag "list: $(tr '\n' '|' <"$C/out")"
}

t_py_dir_defaults() {
  # arrange
  # act
  cm python3 -I "$MODPY" "$P" dir core code
  # assert
  rc_ok
  out_has "modules/core/code"
  cm python3 -I "$MODPY" "$P" dir core infra
  rc_ok
  out_has "modules/core/infra"
}

t_py_dir_override() {
  # arrange
  # act
  cm python3 -I "$MODPY" "$P" dir plain code
  # assert
  rc_ok
  out_has "modules/plain/app"
  cm python3 -I "$MODPY" "$P" dir plain infra
  rc_ok
  out_has "modules/plain/infra"
}

t_py_dir_override_infra() {
  # arrange
  printf '{"modules":{"x":{"infra":{"dir":"ops/x"}}}}\n' >"$P/.github/modules.json"
  # act
  cm python3 -I "$MODPY" "$P" dir x infra
  # assert
  rc_ok
  out_has "ops/x"
}

t_py_services() {
  # arrange
  # act
  cm python3 -I "$MODPY" "$P" services core
  # assert
  rc_ok
  [ "$(tr '\n' ' ' <"$C/out")" = "postgres redis " ] || diag "services: $(tr '\n' '|' <"$C/out")"
  cm python3 -I "$MODPY" "$P" services plain
  rc_ok
  [ ! -s "$C/out" ] || diag "plain deveria não ter serviços: $(tr '\n' '|' <"$C/out")"
}

t_py_invalid_name() {
  # arrange
  printf '{"modules":{"Bad":{}}}\n' >"$P/.github/modules.json"
  # act
  cm python3 -I "$MODPY" "$P" list
  # assert
  rc_fail
  err_has "commons:"
}

t_py_invalid_name_digit_first() {
  # arrange
  printf '{"modules":{"1core":{}}}\n' >"$P/.github/modules.json"
  # act
  cm python3 -I "$MODPY" "$P" list
  # assert
  rc_fail
}

t_py_invalid_json() {
  # arrange
  printf '{ nope' >"$P/.github/modules.json"
  # act
  cm python3 -I "$MODPY" "$P" list
  # assert
  rc_fail
  err_has "commons:"
}

t_py_missing_file() {
  # arrange
  rm "$P/.github/modules.json"
  # act
  cm python3 -I "$MODPY" "$P" list
  # assert
  rc_fail
  err_has "commons:"
}

t_py_unknown_module() {
  # arrange
  # act
  cm python3 -I "$MODPY" "$P" dir nope code
  # assert
  rc_fail
  err_has "commons: módulo nope desconhecido"
}

t_make_hook_args_env() {
  # arrange
  code="$P/modules/core/code"
  # act
  cm make --no-print-directory core.test ENV=remote ARGS=x
  # assert
  rc_ok
  hook_has "ARGS=x"
  hook_has "ENVIRONMENT=remote"
  hook_has "MODULE=core"
  hook_has "PWD=$(phys "$code")"
  hook_has "ENV=unset"
}

t_make_run_console() {
  # arrange
  # act
  cm make --no-print-directory core.console
  # assert
  rc_ok
  hook_has "MODULE=core"
  hook_has "ENVIRONMENT=dev"
}

t_make_run_args() {
  # arrange
  # act
  cm make --no-print-directory core.console ARGS="a b"
  # assert
  rc_ok
  hook_has "ARGS=a b"
}

t_make_plain_override_dir() {
  # arrange
  app="$P/modules/plain/app"
  # act
  cm make --no-print-directory plain.test
  # assert
  rc_ok
  hook_has "MODULE=plain"
  hook_has "PWD=$(phys "$app")"
  hook_has "CI_CACHE_DIR=$app/.ci-cache"
}

t_make_infra_step() {
  # arrange
  infra="$P/modules/core/infra"
  # act
  cm make --no-print-directory core.validate
  # assert
  rc_ok
  hook_has "PWD=$(phys "$infra")"
}

t_make_restricted_guard() {
  # arrange
  # act
  cm make --no-print-directory core.console ENV=prod
  # assert
  rc_fail
  hook_not_ran
}

t_make_restricted_confirm() {
  # arrange
  # act
  cm make --no-print-directory core.console ENV=prod CONFIRM=demo
  # assert
  rc_ok
  hook_has "ENVIRONMENT=prod"
  log_has "ward exec demo::restricted:secrets.core.code.prod"
}

t_make_reserved_run_not_a_target() {
  # arrange
  : >"$P/modules/core/code/run/lint"
  chmod +x "$P/modules/core/code/run/lint"
  printf '#!/bin/sh\nexit 99\n' >"$P/modules/core/code/run/lint"
  # act
  cm make --no-print-directory core.lint
  # assert
  rc_ok
  hook_has "MODULE=core"
}

install_psql() {
  cat >"$C/fakebin/psql" <<'EOF'
#!/bin/sh
{
  printf 'PSQL_ARGS=%s\n' "$*"
  printf 'PWD=%s\n' "$(pwd -P)"
} >"$HOOK_OUT"
EOF
  chmod +x "$C/fakebin/psql"
}

hide_psql() {
  shadow="$C/shadow"
  mkdir -p "$shadow"
  new_path="$C/fakebin"
  old_ifs="$IFS"
  IFS=:
  for dir in $ORIG_PATH; do
    if [ -x "$dir/psql" ]; then
      for entry in "$dir"/*; do
        [ "$(basename "$entry")" = psql ] && continue
        ln -sf "$entry" "$shadow/$(basename "$entry")" 2>/dev/null
      done
      case ":$new_path:" in
        *":$shadow:"*) ;;
        *) new_path="$new_path:$shadow" ;;
      esac
    else
      new_path="$new_path:$dir"
    fi
  done
  IFS="$old_ifs"
  PATH="$new_path"
  export PATH
}

t_db_without_url() {
  # arrange
  install_psql
  # act
  cm "$BIN" db core
  # assert
  rc_fail
  err_has "commons: sem DATABASE_URL"
  hook_not_ran
}

t_db_calls_psql() {
  # arrange
  install_psql
  code="$P/modules/core/code"
  # act
  cm DATABASE_URL=postgres://u@h/db "$BIN" db core
  # assert
  rc_ok
  hook_has "PSQL_ARGS=postgres://u@h/db"
  hook_has "PWD=$(phys "$code")"
  log_has "ward exec demo:secrets.core.code.dev"
}

t_db_without_psql() {
  # arrange
  hide_psql
  # act
  cm DATABASE_URL=postgres://u@h/db "$BIN" db core
  # assert
  rc_fail
  err_has "psql"
  hook_not_ran
}

t_db_via_make() {
  # arrange
  install_psql
  # act
  cm DATABASE_URL=postgres://u@h/db make --no-print-directory core.db
  # assert
  rc_ok
  hook_has "PSQL_ARGS=postgres://u@h/db"
}

t_remote_runs_hook() {
  # arrange
  infra="$P/modules/core/infra"
  # act
  cm "$BIN" remote core one two
  # assert
  rc_ok
  hook_has "HOOK=remote.sh"
  hook_has "MODULE=core"
  hook_has "ENVIRONMENT=remote"
  hook_has "PWD=$(phys "$infra")"
  hook_has "ARGS=one two"
  hook_has "A=sekret1"
  hook_has "I=sekret3"
  hook_has "COMMONS_SECRET_KEYS=A B"
  log_has "ward exec demo:secrets.core.code.remote demo:secrets.core.infra.remote"
}

install_recint() {
  cat >"$C/fakebin/recint" <<'EOF'
#!/bin/sh
printf 'INTERP=recint\n' >"$HOOK_OUT"
EOF
  chmod +x "$C/fakebin/recint"
}

t_remote_executable_hook_uses_shebang() {
  # arrange
  install_recint
  printf '#!/usr/bin/env recint\n' >"$P/modules/core/infra/ops/remote.sh"
  chmod +x "$P/modules/core/infra/ops/remote.sh"
  # act
  cm "$BIN" remote core
  # assert
  rc_ok
  hook_has "INTERP=recint"
}

t_secrets_executable_hook_uses_shebang() {
  # arrange
  install_recint
  printf '#!/usr/bin/env recint\n' >"$P/modules/core/infra/ops/secrets.sh"
  chmod +x "$P/modules/core/infra/ops/secrets.sh"
  # act
  cm "$BIN" secrets core
  # assert
  rc_ok
  hook_has "INTERP=recint"
}

t_remote_non_executable_hook_runs_with_sh() {
  # arrange
  chmod -x "$P/modules/core/infra/ops/remote.sh"
  # act
  cm "$BIN" remote core
  # assert
  [ ! -x "$P/modules/core/infra/ops/remote.sh" ] || diag "hook ainda executável"
  rc_ok
  hook_has "HOOK=remote.sh"
}

t_secrets_non_executable_hook_runs_with_sh() {
  # arrange
  chmod -x "$P/modules/core/infra/ops/secrets.sh"
  # act
  cm "$BIN" secrets core
  # assert
  [ ! -x "$P/modules/core/infra/ops/secrets.sh" ] || diag "hook ainda executável"
  rc_ok
  hook_has "HOOK=secrets.sh"
}

t_aimode_hook_fails() {
  # arrange
  # act
  cm FAKE_WARD_AIMODE=1 "$BIN" hook core test
  # assert
  rc_fail
  err_has "commons: o ward recusou ler demo:secrets.core.code.check: ele roda em modo de agente (rode fora do agente)"
  if grep -q "escopo .* vazio" "$C/err"; then diag "tratou modo de agente como escopo vazio"; fi
  hook_not_ran
  log_lacks "ward exec"
}

t_aimode_keys_fails() {
  # arrange
  # act
  cm FAKE_WARD_AIMODE=1 "$BIN" keys core
  # assert
  rc_fail
  err_has "ele roda em modo de agente (rode fora do agente)"
  never_leaks
}

t_aimode_secrets_fails() {
  # arrange
  # act
  cm FAKE_WARD_AIMODE=1 "$BIN" secrets core
  # assert
  rc_fail
  err_has "ele roda em modo de agente (rode fora do agente)"
  hook_not_ran
  never_leaks
}

t_aimode_remote_fails() {
  # arrange
  # act
  cm FAKE_WARD_AIMODE=1 "$BIN" remote core
  # assert
  rc_fail
  err_has "ele roda em modo de agente (rode fora do agente)"
  hook_not_ran
}

t_nokey_is_not_empty_scope() {
  # arrange
  # act
  cm FAKE_WARD_NOKEY=1 "$BIN" hook core test
  # assert
  rc_fail
  err_has "commons: sem acesso ao vault demo (falta a chave)"
  if grep -q "vazio" "$C/err"; then diag "tratou falta de chave como escopo vazio"; fi
  hook_not_ran
}

t_remote_missing_hook() {
  # arrange
  rm "$P/modules/core/infra/ops/remote.sh"
  # act
  cm "$BIN" remote core
  # assert
  rc_fail
  err_has "commons: core sem modules/core/infra/ops/remote.sh"
  hook_not_ran
}

t_remote_collision() {
  # arrange
  # act
  cm FAKE_WARD_PAIRS=A=sekret1 FAKE_WARD_INFRA=A=sekret9 "$BIN" remote core
  # assert
  rc_fail
  err_has "A existe em demo:secrets.core.code.remote e demo:secrets.core.infra.remote"
  hook_not_ran
  log_lacks "ward exec"
  never_leaks
}

t_remote_restricted_guard() {
  # arrange
  # act
  cm ENV=prod "$BIN" remote core
  # assert
  rc_fail
  hook_not_ran
}

t_remote_via_make() {
  # arrange
  # act
  cm make --no-print-directory core.remote ARGS=x
  # assert
  rc_ok
  hook_has "HOOK=remote.sh"
  hook_has "ARGS=x"
}

t_secrets_green() {
  # arrange
  infra="$P/modules/core/infra"
  # act
  cm "$BIN" secrets core
  # assert
  rc_ok
  hook_has "HOOK=secrets.sh"
  hook_has "COMMONS_SECRET_KEYS=A B"
  hook_has "PWD=$(phys "$infra")"
  hook_has "ENVIRONMENT=remote"
  log_has "demo:secrets.core.code.remote"
}

t_secrets_env_override() {
  # arrange
  # act
  cm ENV=check "$BIN" secrets core
  # assert
  rc_ok
  hook_has "ENVIRONMENT=check"
  log_has "demo:secrets.core.code.check"
}

t_secrets_empty_value() {
  # arrange
  # act
  cm "FAKE_WARD_PAIRS=A=sekret1\nB=\nC=CHANGE_ME\nD=sekret4" "$BIN" secrets core
  # assert
  rc_fail
  err_has "commons: sem valor: B C"
  hook_not_ran
  never_leaks
}

t_secrets_change_me_only() {
  # arrange
  # act
  cm "FAKE_WARD_PAIRS=A=sekret1\nB=CHANGE_ME" "$BIN" secrets core
  # assert
  rc_fail
  err_has "commons: sem valor: B"
  hook_not_ran
  never_leaks
}

t_secrets_empty_scope() {
  # arrange
  # act
  cm FAKE_WARD_EMPTY=1 "$BIN" secrets core
  # assert
  rc_fail
  err_has "escopo demo:secrets.core.code.remote vazio"
  hook_not_ran
}

t_secrets_no_key() {
  # arrange
  # act
  cm FAKE_WARD_NOKEY=1 "$BIN" secrets core
  # assert
  rc_fail
  err_has "sem acesso ao vault demo"
  hook_not_ran
  never_leaks
}

t_secrets_missing_hook() {
  # arrange
  rm "$P/modules/core/infra/ops/secrets.sh"
  # act
  cm "$BIN" secrets core
  # assert
  rc_fail
  err_has "commons: core sem modules/core/infra/ops/secrets.sh"
  hook_not_ran
}

t_secrets_collision() {
  # arrange
  # act
  cm FAKE_WARD_PAIRS=A=sekret1 FAKE_WARD_INFRA=A=sekret9 "$BIN" secrets core
  # assert
  rc_fail
  err_has "A existe em"
  hook_not_ran
  never_leaks
}

t_secrets_restricted_guard() {
  # arrange
  # act
  cm ENV=prod "$BIN" secrets core
  # assert
  rc_fail
  hook_not_ran
  never_leaks
}

t_secrets_via_make() {
  # arrange
  # act
  cm make --no-print-directory core.secrets
  # assert
  rc_ok
  hook_has "HOOK=secrets.sh"
  hook_has "COMMONS_SECRET_KEYS=A B"
}

t_secrets_no_leak_on_any_failure() {
  # arrange
  # act
  cm "FAKE_WARD_PAIRS=A=sekret1\nB=" "$BIN" secrets core
  # assert
  rc_fail
  never_leaks
  cm FAKE_WARD_PAIRS=A=sekret1 FAKE_WARD_INFRA=A=sekret2 "$BIN" secrets core
  rc_fail
  never_leaks
  cm FAKE_WARD_PAIRS=A=sekret1 FAKE_WARD_INFRA=A=sekret2 "$BIN" remote core
  rc_fail
  never_leaks
  cm FAKE_WARD_NOKEY=1 "$BIN" secrets core
  rc_fail
  never_leaks
}

t_conform_green() {
  # arrange
  # act
  cm "$BIN" conform
  # assert
  rc_ok
  err_has "conform ok"
}

t_conform_green_via_make() {
  # arrange
  # act
  cm make --no-print-directory conform
  # assert
  rc_ok
}

t_conform_red_via_make() {
  # arrange
  ctx_without COMMONS_REF
  # act
  cm make --no-print-directory conform
  # assert
  rc_fail
  err_has "commons.ctx"
  err_has "COMMONS_REF"
}

t_conform_no_ctx() {
  # arrange
  rm "$P/commons.ctx"
  # act
  cm "$BIN" conform
  # assert
  rc_fail
  err_has "commons.ctx"
}

t_conform_ctx_missing_key() {
  # arrange
  ctx_without COMMONS_PROJECT
  # act
  cm "$BIN" conform
  # assert
  rc_fail
  err_has "commons.ctx"
  err_has "COMMONS_PROJECT"
}

t_conform_ctx_each_required_key() {
  # arrange
  original=$(cat "$P/commons.ctx")
  for key in COMMONS_PROJECT COMMONS_ENVS COMMONS_ENV_LOCAL COMMONS_ENV_CHECK COMMONS_ENV_REMOTE COMMONS_REF; do
    printf '%s\n' "$original" >"$P/commons.ctx"
    ctx_without "$key"
    # act
    cm "$BIN" conform
    # assert
    rc_fail
    err_has "$key"
  done
}

t_conform_ctx_env_outside_envs() {
  # arrange
  sed -e 's/^COMMONS_ENV_LOCAL=.*/COMMONS_ENV_LOCAL=nope/' "$P/commons.ctx" >"$P/commons.ctx.new" && mv "$P/commons.ctx.new" "$P/commons.ctx"
  # act
  cm "$BIN" conform
  # assert
  rc_fail
  err_has "commons.ctx"
  err_has "nope"
}

t_conform_modules_missing() {
  # arrange
  rm "$P/.github/modules.json"
  # act
  cm "$BIN" conform
  # assert
  rc_fail
  err_has ".github/modules.json"
}

t_conform_modules_invalid() {
  # arrange
  printf '{ nope' >"$P/.github/modules.json"
  # act
  cm "$BIN" conform
  # assert
  rc_fail
  err_has ".github/modules.json"
}

t_conform_modules_invalid_name() {
  # arrange
  printf '{"modules":{"Bad":{}}}\n' >"$P/.github/modules.json"
  # act
  cm "$BIN" conform
  # assert
  rc_fail
  err_has ".github/modules.json"
  err_has "Bad"
}

t_conform_reserved_run_names() {
  # arrange
  for name in lint audit test build validate plan shell db keys remote secrets; do
    printf '#!/bin/sh\n' >"$P/modules/core/code/run/$name"
    # act
    cm "$BIN" conform
    # assert
    rc_fail
    err_has "modules/core/code/run/$name"
    rm -f "$P/modules/core/code/run/$name"
  done
}

t_conform_reserved_run_in_override_dir() {
  # arrange
  mkdir -p "$P/modules/plain/app/run"
  printf '#!/bin/sh\n' >"$P/modules/plain/app/run/lint"
  # act
  cm "$BIN" conform
  # assert
  rc_fail
  err_has "modules/plain/app/run/lint"
}

t_conform_ops_outside_vocabulary() {
  # arrange
  printf '#!/bin/sh\n' >"$P/modules/core/infra/ops/deploy.sh"
  # act
  cm "$BIN" conform
  # assert
  rc_fail
  err_has "modules/core/infra/ops/deploy.sh"
}

t_conform_compose_missing_fragment() {
  # arrange
  printf 'include:\n  - .commons/compose/x.yml\n' >"$P/compose.yml"
  # act
  cm "$BIN" conform
  # assert
  rc_fail
  err_has "compose.yml"
  err_has ".commons/compose/x.yml"
}

t_conform_compose_existing_fragment() {
  # arrange
  rm "$P/.commons"
  mkdir -p "$P/.commons/compose"
  : >"$P/.commons/compose/x.yml"
  printf 'include:\n  - .commons/compose/x.yml\n' >"$P/compose.yml"
  # act
  cm "$BIN" conform
  # assert
  rc_ok
}

t_conform_compose_absent_is_green() {
  # arrange
  rm -f "$P/compose.yml"
  # act
  cm "$BIN" conform
  # assert
  rc_ok
}

t_conform_multiple_violations() {
  # arrange
  ctx_without COMMONS_REF
  printf '#!/bin/sh\n' >"$P/modules/core/code/run/lint"
  printf '#!/bin/sh\n' >"$P/modules/core/infra/ops/deploy.sh"
  printf 'include:\n  - .commons/compose/x.yml\n' >"$P/compose.yml"
  # act
  cm "$BIN" conform
  # assert
  rc_fail
  err_has "COMMONS_REF"
  err_has "modules/core/code/run/lint"
  err_has "modules/core/infra/ops/deploy.sh"
  err_has ".commons/compose/x.yml"
}

run_case "hook: cwd no dir code, MODULE, ENVIRONMENT=check, CI_CACHE_DIR, TAG vazio" t_hook_code
run_case "hook: lint, audit e build rodam no dir code (build usa o env remote)" t_hook_steps_code
run_case "hook infra: validate lê o escopo infra" t_hook_infra
run_case "hook infra: plan usa o env remote e o escopo infra" t_hook_infra_plan_remote
run_case "ENV=remote muda o ambiente e o escopo" t_env_remote
run_case "precedência: ENV vence ENVIRONMENT" t_env_over_environment
run_case "precedência: ENVIRONMENT vence o default" t_environment_over_default
run_case "precedência: sem nada vale o default do comando" t_default_env
run_case "ENV não vaza ao hook" t_env_not_leaked
run_case "ENV não vaza ao shell" t_shell_env_not_leaked
run_case "chave faltando no ctx via make core.shell" t_missing_key
run_case "chave faltando no ctx via bin" t_missing_key_direct
run_case "make core.test ENV=zzz: ambiente fora de COMMONS_ENVS" t_env_invalid
run_case "COMMONS_ENV_* fora de COMMONS_ENVS" t_ctx_env_outside_envs
run_case "sem ward: # COMMONS_VAULT=x não chama ward" t_no_ward
run_case "escopo vazio: avisa e segue sem ward exec" t_empty_scope
run_case "escopo inexistente no ward: hook avisa vazio e segue" t_noscope_hook_warns
run_case "escopo inexistente no ward: keys falha como escopo vazio" t_noscope_keys_fails
run_case "escopo inexistente no ward: secrets falha como escopo vazio" t_noscope_secrets_fails
run_case "sem chave do vault restricted" t_no_restricted_key
run_case "guarda: ENV=prod sem TTY e sem CONFIRM falha sem rodar" t_guard_without_confirm
run_case "guarda: CONFIRM errado falha" t_guard_wrong_confirm
run_case "guarda: CONFIRM=demo roda com o vault restricted" t_guard_confirm
run_case "guarda: GITHUB_ACTIONS=true dispensa a confirmação" t_guard_github_actions
run_case "guarda: ENVIRONMENT=prod também é guardado" t_guard_via_environment
run_case "vault default fora dos ambientes restritos" t_default_vault_outside_restricted
run_case "mise sem mise.toml falha citando o dir" t_no_mise_toml
run_case "step fora do vocabulário é rejeitado" t_step_outside_vocabulary
run_case "console não é step de hook" t_step_console_not_a_hook
run_case "script não executável roda via sh" t_script_not_executable
run_case "keys imprime só os nomes, nunca os valores" t_keys_names_only
run_case "keys via make core.keys" t_keys_via_make
run_case "keys falha com escopo vazio" t_keys_empty_scope_fails
run_case "keys falha sem a chave do vault" t_keys_no_key_fails
run_case "keys: nomes limpos sem ANSI nem legenda" t_keys_clean_names
run_case "secrets: valor com = e espaços não quebra a detecção" t_secrets_value_with_equals_and_spaces
run_case "secrets: valores com = e espaços passam" t_secrets_equals_value_ok
run_case "keys respeita a guarda de ambiente restrito" t_keys_restricted_guard
run_case "run core console passa args e variáveis de paridade" t_run_args
run_case "run usa ENV=remote quando pedido" t_run_env_remote
run_case "run respeita a guarda de ambiente restrito" t_run_restricted_guard
run_case "run de script inexistente falha" t_run_missing_script
run_case "módulo desconhecido falha" t_unknown_module
run_case "nome de módulo inválido na linha de comando falha" t_invalid_module_name
run_case "nome de módulo inválido no modules.json falha" t_invalid_name_in_modules_json
run_case "modules.py list" t_py_list
run_case "modules.py dir com defaults" t_py_dir_defaults
run_case "modules.py dir com override de code.dir" t_py_dir_override
run_case "modules.py dir com override de infra.dir" t_py_dir_override_infra
run_case "modules.py services" t_py_services
run_case "modules.py nome inválido" t_py_invalid_name
run_case "modules.py nome começando com dígito" t_py_invalid_name_digit_first
run_case "modules.py JSON inválido" t_py_invalid_json
run_case "modules.py sem modules.json" t_py_missing_file
run_case "modules.py módulo desconhecido" t_py_unknown_module
run_case "make core.test ENV=remote ARGS=x" t_make_hook_args_env
run_case "make core.console" t_make_run_console
run_case "make core.console ARGS com espaço" t_make_run_args
run_case "make plain.test usa o code.dir customizado" t_make_plain_override_dir
run_case "make core.validate roda no dir infra" t_make_infra_step
run_case "make core.console ENV=prod sem CONFIRM falha" t_make_restricted_guard
run_case "make core.console ENV=prod CONFIRM=demo roda" t_make_restricted_confirm
run_case "make: run/lint reservado não vira target e o hook vence" t_make_reserved_run_not_a_target
run_case "db: sem DATABASE_URL falha" t_db_without_url
run_case "db: chama psql com DATABASE_URL no dir code" t_db_calls_psql
run_case "db: sem psql falha" t_db_without_psql
run_case "make core.db" t_db_via_make
run_case "remote: roda ops/remote.sh no dir infra com env dos dois escopos e ARGS" t_remote_runs_hook
run_case "remote: hook ausente falha citando o caminho" t_remote_missing_hook
run_case "remote: colisão entre escopos code e infra falha sem rodar o hook" t_remote_collision
run_case "remote respeita a guarda de ambiente restrito" t_remote_restricted_guard
run_case "make core.remote ARGS=x" t_remote_via_make
run_case "remote: hook executável com shebang próprio roda direto" t_remote_executable_hook_uses_shebang
run_case "secrets: hook executável com shebang próprio roda direto" t_secrets_executable_hook_uses_shebang
run_case "remote: hook não executável roda via sh" t_remote_non_executable_hook_runs_with_sh
run_case "secrets: hook não executável roda via sh" t_secrets_non_executable_hook_runs_with_sh
run_case "modo de agente: hook falha sem rodar" t_aimode_hook_fails
run_case "modo de agente: keys falha" t_aimode_keys_fails
run_case "modo de agente: secrets falha sem rodar o hook" t_aimode_secrets_fails
run_case "modo de agente: remote falha sem rodar o hook" t_aimode_remote_fails
run_case "sem chave do vault não vira escopo vazio" t_nokey_is_not_empty_scope
run_case "secrets: caso verde exporta COMMONS_SECRET_KEYS e roda o hook" t_secrets_green
run_case "secrets: ENV=check sobrescreve o default remote" t_secrets_env_override
run_case "secrets: valor vazio e CHANGE_ME listam só os nomes" t_secrets_empty_value
run_case "secrets: só CHANGE_ME" t_secrets_change_me_only
run_case "secrets: escopo vazio falha" t_secrets_empty_scope
run_case "secrets: sem chave do vault falha" t_secrets_no_key
run_case "secrets: hook ausente falha" t_secrets_missing_hook
run_case "secrets: colisão entre escopos falha" t_secrets_collision
run_case "secrets respeita a guarda de ambiente restrito" t_secrets_restricted_guard
run_case "make core.secrets" t_secrets_via_make
run_case "secrets/remote: nenhum valor vaza em qualquer falha" t_secrets_no_leak_on_any_failure
run_case "conform: verde no fixture" t_conform_green
run_case "make conform: verde" t_conform_green_via_make
run_case "make conform: vermelho" t_conform_red_via_make
run_case "conform: sem commons.ctx" t_conform_no_ctx
run_case "conform: ctx sem chave obrigatória" t_conform_ctx_missing_key
run_case "conform: cada chave obrigatória do ctx" t_conform_ctx_each_required_key
run_case "conform: ENV_* fora de ENVS" t_conform_ctx_env_outside_envs
run_case "conform: modules.json ausente" t_conform_modules_missing
run_case "conform: modules.json inválido" t_conform_modules_invalid
run_case "conform: nome de módulo inválido" t_conform_modules_invalid_name
run_case "conform: run/ com nomes reservados" t_conform_reserved_run_names
run_case "conform: run/ reservado em code.dir customizado" t_conform_reserved_run_in_override_dir
run_case "conform: ops fora do vocabulário" t_conform_ops_outside_vocabulary
run_case "conform: compose com fragment inexistente" t_conform_compose_missing_fragment
run_case "conform: compose com fragment existente" t_conform_compose_existing_fragment
run_case "conform: sem compose.yml é verde" t_conform_compose_absent_is_green
run_case "conform: múltiplas violações juntas" t_conform_multiple_violations

have_docker() {
  command -v docker >/dev/null 2>&1 && PATH="$ORIG_PATH" docker compose version >/dev/null 2>&1
}

have_daemon() {
  have_docker && PATH="$ORIG_PATH" docker info >/dev/null 2>&1
}

install_docker() {
  cat >"$C/fakebin/docker" <<'SH'
#!/bin/sh
if [ "$1" = compose ] && [ "$2" = version ]; then
  printf '%s\n' "${FAKE_COMPOSE_VERSION-2.27.0}"
  exit 0
fi
printf 'docker %s\n' "$*" >>"$FAKE_LOG"
printf 'COMPOSE_PROJECT_NAME=%s\n' "${COMPOSE_PROJECT_NAME-unset}" >>"$FAKE_LOG"
SH
  chmod +x "$C/fakebin/docker"
}

frag() {
  printf '%s/compose/%s.yml' "$REPO" "$1"
}

frag_has() {
  grep -qF -- "$2" "$(frag "$1")" || diag "$1.yml sem '$2'"
}

frag_lacks() {
  ! grep -qiF -- "$2" "$(frag "$1")" || diag "$1.yml tem '$2' e não devia"
}

t_compose_config_valid() {
  # arrange
  if ! have_docker; then printf 'ok - skip: sem docker compose\n'; return; fi
  # act
  for f in database cache mail; do
    PATH="$ORIG_PATH" docker compose -f "$(frag "$f")" config -q >"$C/out" 2>"$C/err"
    RC=$?
    # assert
    [ "$RC" -eq 0 ] || diag "$f.yml inválido: $(tr '\n' '|' <"$C/err")"
  done
}

t_compose_database_contract() {
  # arrange
  # act
  # assert
  frag_has database "image: postgres:16-alpine"
  frag_has database "POSTGRES_USER: postgres"
  frag_has database "POSTGRES_PASSWORD: postgres"
  frag_has database "\"\${COMMONS_DB_PORT:-5432}:5432\""
  frag_has database "database_data:/var/lib/postgresql/data"
  frag_has database "healthcheck:"
  frag_has database "pg_isready"
  frag_has database "  database:"
}

t_compose_cache_contract() {
  # arrange
  # act
  # assert
  frag_has cache "image: redis:7-alpine"
  frag_has cache "\"\${COMMONS_CACHE_PORT:-6379}:6379\""
  frag_has cache "healthcheck:"
  frag_has cache "redis-cli"
  frag_has cache "  cache:"
}

t_compose_mail_contract() {
  # arrange
  # act
  # assert
  frag_has mail "image: axllent/mailpit:v1"
  frag_has mail "\"\${COMMONS_MAIL_PORT:-8025}:8025\""
  frag_has mail "\"\${COMMONS_SMTP_PORT:-1025}:1025\""
  frag_has mail "healthcheck:"
  frag_has mail "  mail:"
}

t_compose_fragments_are_generic() {
  # arrange
  # act
  # assert
  for f in database cache mail; do
    frag_lacks "$f" "DATABASE_URL"
    frag_lacks "$f" "demo"
    frag_lacks "$f" "name:"
    frag_lacks "$f" "production"
    frag_lacks "$f" "staging"
    frag_lacks "$f" "development"
    frag_lacks "$f" "COMMONS_PROJECT"
  done
}

t_up_runs_compose_up_wait() {
  # arrange
  install_docker
  # act
  cm "$BIN" up
  # assert
  rc_ok
  log_has "docker compose up -d --wait"
  log_has "COMPOSE_PROJECT_NAME=demo"
}

t_down_without_volumes() {
  # arrange
  install_docker
  # act
  cm "$BIN" down
  # assert
  rc_ok
  log_has "docker compose down --remove-orphans"
  log_lacks " -v"
  log_lacks "--volumes"
  log_has "COMPOSE_PROJECT_NAME=demo"
}

t_logs_follows() {
  # arrange
  install_docker
  # act
  cm "$BIN" logs
  # assert
  rc_ok
  log_has "docker compose logs -f"
  log_has "COMPOSE_PROJECT_NAME=demo"
}

t_up_forwards_args() {
  # arrange
  install_docker
  # act
  cm "$BIN" up database
  # assert
  rc_ok
  log_has "docker compose up -d --wait database"
}

t_compose_old_version_fails() {
  # arrange
  install_docker
  for sub in up down logs; do
    # act
    cm FAKE_COMPOSE_VERSION=2.19.0 "$BIN" "$sub"
    # assert
    rc_fail
    err_has "commons: docker compose >= 2.20"
    log_lacks "docker compose $sub"
  done
}

t_compose_v1_version_fails() {
  # arrange
  install_docker
  # act
  cm FAKE_COMPOSE_VERSION=1.29.2 "$BIN" up
  # assert
  rc_fail
  err_has "commons: docker compose >= 2.20"
}

t_compose_min_version_ok() {
  # arrange
  install_docker
  # act
  cm FAKE_COMPOSE_VERSION=2.20.0 "$BIN" up
  # assert
  rc_ok
  log_has "docker compose up -d --wait"
}

t_compose_without_docker_fails() {
  # arrange
  mkdir "$C/emptybin"
  for t in sh env dirname cat grep tr sed awk python3 git uname mktemp; do
    src=$(PATH="$ORIG_PATH" command -v "$t") && ln -s "$src" "$C/emptybin/$t"
  done
  # act
  ( cd "$P" && PATH="$C/emptybin" "$BIN" up ) </dev/null >"$C/out" 2>"$C/err"
  RC=$?
  # assert
  rc_fail
  err_has "commons: docker compose >= 2.20"
}

t_make_up() {
  # arrange
  install_docker
  # act
  cm make --no-print-directory up
  # assert
  rc_ok
  log_has "docker compose up -d --wait"
  log_has "COMPOSE_PROJECT_NAME=demo"
}

t_make_down() {
  # arrange
  install_docker
  # act
  cm make --no-print-directory down
  # assert
  rc_ok
  log_has "docker compose down --remove-orphans"
  log_lacks "--volumes"
}

t_make_logs() {
  # arrange
  install_docker
  # act
  cm make --no-print-directory logs
  # assert
  rc_ok
  log_has "docker compose logs -f"
}

mk_init_project() {
  I="$C/initproj"
  mkdir -p "$I/.commons"
  ( cd "$I" && git init -q . )
  cp -R "$REPO/bin" "$REPO/lib" "$REPO/make" "$REPO/compose" "$REPO/commons.ctx.example" "$I/.commons/"
}

init_run() {
  ( cd "$I" && env "$@" ) </dev/null >"$C/out" 2>"$C/err"
  RC=$?
}

init_modules() {
  mkdir -p "$I/.github"
  cp "$HERE/fixtures/project/.github/modules.json" "$I/.github/modules.json"
}

init_sum() {
  ( cd "$I" && find . -path ./.commons -prune -o -path ./.git -prune -o -type f -print | LC_ALL=C sort | while read -r f; do cksum "$f"; done )
}

file_has() {
  grep -qxF -- "$2" "$1" || diag "$1 sem a linha '$2'; conteúdo: $(tr '\n' '|' <"$1")"
}

t_init_creates_files() {
  # arrange
  mk_init_project
  init_modules
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  file_has "$I/Makefile" "include .commons/make/main.mk"
  cmp -s "$I/commons.ctx" "$I/.commons/commons.ctx.example" || diag "commons.ctx difere do example"
  file_has "$I/compose.yml" "include:"
  file_has "$I/compose.yml" "  - .commons/compose/database.yml"
  file_has "$I/compose.yml" "  - .commons/compose/cache.yml"
  file_has "$I/compose.yml" "#  - .commons/compose/mail.yml"
  file_has "$I/.gitignore" ".ci-cache/"
}

t_init_runs_conform_and_lists_missing() {
  # arrange
  mk_init_project
  init_modules
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  [ -s "$C/err" ] || [ -s "$C/out" ] || diag "init não listou o que falta"
  grep -q "commons.ctx" "$C/out" "$C/err" || diag "saída não cita commons.ctx"
}

t_init_second_run_changes_nothing() {
  # arrange
  mk_init_project
  init_modules
  init_run .commons/bin/init
  init_sum >"$C/before"
  # act
  init_run .commons/bin/init
  init_sum >"$C/after"
  # assert
  rc_ok
  cmp -s "$C/before" "$C/after" || diag "segunda execução alterou arquivos"
  [ -s "$C/before" ] || diag "nenhum arquivo criado"
  [ "$(grep -cx '.ci-cache/' "$I/.gitignore")" -eq 1 ] || diag ".ci-cache/ duplicado"
}

t_init_second_run_changes_nothing_with_user_files() {
  # arrange
  mk_init_project
  init_modules
  printf 'node_modules/\n' >"$I/.gitignore"
  init_run .commons/bin/init
  init_sum >"$C/before"
  # act
  init_run .commons/bin/init
  init_sum >"$C/after"
  # assert
  rc_ok
  cmp -s "$C/before" "$C/after" || diag "segunda execução alterou arquivos"
  file_has "$I/.gitignore" "node_modules/"
}

t_init_existing_makefile_untouched() {
  # arrange
  mk_init_project
  init_modules
  printf 'all:\n\t@echo hi\n' >"$I/Makefile"
  cksum "$I/Makefile" >"$C/before"
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  cksum "$I/Makefile" >"$C/after"
  cmp -s "$C/before" "$C/after" || diag "Makefile alterado"
  err_has "Makefile sem 'include .commons/make/main.mk'"
}

t_init_existing_makefile_with_include_no_warning() {
  # arrange
  mk_init_project
  init_modules
  printf 'include .commons/make/main.mk\nall:\n\t@echo hi\n' >"$I/Makefile"
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  ! grep -qF "Makefile sem" "$C/err" || diag "avisou com include presente"
}

t_init_without_modules_json() {
  # arrange
  mk_init_project
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  file_has "$I/compose.yml" "services: {}"
}

t_init_without_services() {
  # arrange
  mk_init_project
  mkdir -p "$I/.github"
  printf '{"modules":{"core":{}}}\n' >"$I/.github/modules.json"
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  file_has "$I/compose.yml" "services: {}"
}

t_init_only_postgres() {
  # arrange
  mk_init_project
  mkdir -p "$I/.github"
  printf '{"modules":{"core":{"services":["postgres"]}}}\n' >"$I/.github/modules.json"
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  file_has "$I/compose.yml" "  - .commons/compose/database.yml"
  ! grep -qx "  - .commons/compose/cache.yml" "$I/compose.yml" || diag "cache incluído sem redis"
}

t_init_existing_compose_untouched() {
  # arrange
  mk_init_project
  init_modules
  printf 'services:\n  app:\n    image: x\n' >"$I/compose.yml"
  cksum "$I/compose.yml" >"$C/before"
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  cksum "$I/compose.yml" >"$C/after"
  cmp -s "$C/before" "$C/after" || diag "compose.yml alterado"
}

t_init_existing_ctx_untouched() {
  # arrange
  mk_init_project
  init_modules
  printf 'COMMONS_PROJECT=mine\n' >"$I/commons.ctx"
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  file_has "$I/commons.ctx" "COMMONS_PROJECT=mine"
}

t_init_outside_project_root_fails() {
  # arrange
  mk_init_project
  rm -rf "$I/.git"
  mkdir -p "$C/outer"
  ( cd "$C/outer" && git init -q . )
  mv "$I" "$C/outer/inner"
  I="$C/outer/inner"
  # act
  ( cd "$I" && .commons/bin/init ) </dev/null >"$C/out" 2>"$C/err"
  RC=$?
  # assert
  rc_ok
  [ -f "$C/outer/Makefile" ] || diag "esperava Makefile na raiz do repo git"
}

t_init_under_symlink() {
  # arrange
  mk_init_project
  init_modules
  mv "$I" "$C/realproj"
  ln -s "$C/realproj" "$C/linkproj"
  I="$C/linkproj"
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  [ -f "$C/realproj/Makefile" ] || diag "Makefile não criado na raiz real"
  [ -f "$C/realproj/commons.ctx" ] || diag "commons.ctx não criado"
  file_has "$C/realproj/.gitignore" ".ci-cache/"
}

t_init_gitignore_without_trailing_newline() {
  # arrange
  mk_init_project
  init_modules
  printf 'node_modules/' >"$I/.gitignore"
  # act
  init_run .commons/bin/init
  # assert
  rc_ok
  file_has "$I/.gitignore" "node_modules/"
  file_has "$I/.gitignore" ".ci-cache/"
  [ "$(wc -l <"$I/.gitignore" | tr -d ' ')" = "2" ] || diag "esperava 2 linhas: $(tr '\n' '|' <"$I/.gitignore")"
}

t_init_generated_compose_is_valid() {
  # arrange
  if ! have_docker; then printf 'ok - skip: sem docker compose\n'; return; fi
  mk_init_project
  init_modules
  init_run .commons/bin/init
  # act
  ( cd "$I" && PATH="$ORIG_PATH" docker compose config -q ) >"$C/out" 2>"$C/err"
  RC=$?
  # assert
  rc_ok
}

t_compose_real_up_down_keeps_volume() {
  # arrange
  if ! have_daemon; then printf 'ok - skip: sem daemon docker\n'; return; fi
  port=$(python3 -I -c 'import socket
a=socket.socket(); a.bind(("127.0.0.1",0)); b=socket.socket(); b.bind(("127.0.0.1",0))
print(a.getsockname()[1], b.getsockname()[1])')
  cport=${port% *}
  dport=${port#* }
  mk_init_project
  init_modules
  printf 'COMMONS_PROJECT=c3test%s\nCOMMONS_ENVS=dev,check,remote\nCOMMONS_ENV_LOCAL=dev\nCOMMONS_ENV_CHECK=check\nCOMMONS_ENV_REMOTE=remote\nCOMMONS_REF=v1\n' "$$" >"$I/commons.ctx"
  printf 'include:\n  - .commons/compose/database.yml\n  - .commons/compose/cache.yml\n' >"$I/compose.yml"
  proj="c3test$$"
  PATH="$ORIG_PATH"
  # act
  init_run COMMONS_CACHE_PORT="$cport" COMMONS_DB_PORT="$dport" .commons/bin/commons up
  up_rc=$RC
  docker volume ls -q --filter "name=${proj}_database_data" >"$C/vol_up" 2>/dev/null
  init_run COMMONS_CACHE_PORT="$cport" COMMONS_DB_PORT="$dport" .commons/bin/commons down
  down_rc=$RC
  docker volume ls -q --filter "name=${proj}_database_data" >"$C/vol_down" 2>/dev/null
  docker volume rm "${proj}_database_data" >/dev/null 2>&1
  PATH="$C/fakebin:$ORIG_PATH"
  # assert
  [ "$up_rc" -eq 0 ] || diag "up falhou rc=$up_rc"
  [ "$down_rc" -eq 0 ] || diag "down falhou rc=$down_rc"
  grep -qx "${proj}_database_data" "$C/vol_up" || diag "volume não existia após up"
  grep -qx "${proj}_database_data" "$C/vol_down" || diag "down removeu o volume database_data"
}

mk_gh_project() {
  GR="$C/remote.git"
  git init -q --bare -b main "$GR"
  ( cd "$P" && git init -q -b main . && git remote add origin "$GR" )
  if [ "${1-}" = workflow ]; then
    mkdir -p "$P/.github/workflows"
    printf 'name: %s\non: pull_request\n' "${2-check/pr}" >"$P/.github/workflows/pr.yml"
    ( cd "$P" && git add .github/workflows/pr.yml )
  else
    printf 'x\n' >"$P/readme.txt"
    ( cd "$P" && git add readme.txt )
  fi
  ( cd "$P" && git -c user.name=t -c user.email=t@t commit -q -m init && git push -q origin main && git fetch -q origin )
}

gh_ctx() {
  printf '%s\n' "$@" >>"$P/commons.ctx"
}

stdin_has() {
  grep -qF -- "$1" "$FAKE_LOG.stdin" 2>/dev/null || diag "stdin do gh sem '$1'; stdin: $(tr '\n' '|' <"$FAKE_LOG.stdin" 2>/dev/null)"
}

stdin_lacks() {
  ! grep -qF -- "$1" "$FAKE_LOG.stdin" 2>/dev/null || diag "stdin do gh tem '$1' e não devia"
}

gh_count() {
  grep -cF -- "$1" "$FAKE_LOG" || true
}

t_gh_secrets_set() {
  # arrange
  printf 'sekret-token\n' >"$P/token.key"
  printf 'sekret-other\n' >"$P/other.key"
  gh_ctx "COMMONS_GITHUB_SECRETS=TOKEN:token.key,OTHER:other.key"
  # act
  cm "$BIN" github-setup
  # assert
  rc_ok
  log_has "gh secret set TOKEN -R demo/repo"
  log_has "gh secret set OTHER -R demo/repo"
  stdin_has "secret set TOKEN -R demo/repo	sekret-token"
  stdin_has "secret set OTHER -R demo/repo	sekret-other"
  never_leaks
}

t_gh_secrets_missing_file() {
  # arrange
  printf 'sekret-other\n' >"$P/other.key"
  gh_ctx "COMMONS_GITHUB_SECRETS=GONE:gone.key,OTHER:other.key"
  # act
  cm "$BIN" github-setup
  # assert
  rc_ok
  err_has "secret GONE pulado"
  log_lacks "gh secret set GONE"
  log_has "gh secret set OTHER -R demo/repo"
  never_leaks
}

t_gh_without_secrets_var() {
  # arrange
  # act
  cm "$BIN" github-setup
  # assert
  rc_ok
  log_lacks "gh secret set"
}

t_gh_merge_patch() {
  # arrange
  # act
  cm "$BIN" github-setup
  # assert
  rc_ok
  log_has "gh api -X PATCH repos/demo/repo"
  log_has "allow_merge_commit=false"
  log_has "allow_squash_merge=true"
  log_has "allow_rebase_merge=true"
  log_has "delete_branch_on_merge=true"
}

t_gh_ruleset_deferred() {
  # arrange
  mk_gh_project
  gh_ctx "COMMONS_REQUIRED_CHECK=check/pr"
  # act
  cm "$BIN" github-setup
  # assert
  rc_ok
  err_has "ruleset adiado: nenhum workflow em main declara check/pr"
  log_lacks "-X POST"
  log_lacks "-X PUT"
  log_lacks "/rulesets"
}

t_gh_ruleset_created() {
  # arrange
  mk_gh_project workflow
  gh_ctx "COMMONS_REQUIRED_CHECK=check/pr"
  # act
  cm "$BIN" github-setup
  # assert
  rc_ok
  log_has "gh api -X POST repos/demo/repo/rulesets --input -"
  log_lacks "-X PUT"
  stdin_has '"name":"commons-default-branch"'
  stdin_has '"context":"check/pr"'
  stdin_has '"integration_id":15368'
  stdin_has '"strict_required_status_checks_policy":true'
}

t_gh_ruleset_idempotent() {
  # arrange
  mk_gh_project workflow
  gh_ctx "COMMONS_REQUIRED_CHECK=check/pr"
  # act
  cm "$BIN" github-setup
  rc_ok
  cm GH_RULESET_ID=7 "$BIN" github-setup
  # assert
  rc_ok
  log_has "gh api -X PUT repos/demo/repo/rulesets/7 --input -"
  [ "$(gh_count '-X POST')" -eq 1 ] || diag "ruleset duplicado: $(gh_count '-X POST') POSTs"
  stdin_has "-X PUT repos/demo/repo/rulesets/7 --input -	{"
}

t_gh_ruleset_existing_put_only() {
  # arrange
  mk_gh_project workflow
  gh_ctx "COMMONS_REQUIRED_CHECK=check/pr"
  # act
  cm GH_RULESET_ID=42 "$BIN" github-setup
  # assert
  rc_ok
  log_has "gh api -X PUT repos/demo/repo/rulesets/42 --input -"
  log_lacks "-X POST"
}

t_gh_ruleset_partial_name_deferred() {
  # arrange
  mk_gh_project workflow check/pr-x
  gh_ctx "COMMONS_REQUIRED_CHECK=check/pr"
  # act
  cm "$BIN" github-setup
  # assert
  rc_ok
  err_has "ruleset adiado: nenhum workflow em main declara check/pr"
  log_lacks "-X POST"
  log_lacks "-X PUT"
  log_lacks "/rulesets"
}

t_gh_ruleset_duplicate_ids() {
  # arrange
  mk_gh_project workflow
  gh_ctx "COMMONS_REQUIRED_CHECK=check/pr"
  ids=$(printf '7\n8')
  # act
  cm "GH_RULESET_ID=$ids" "$BIN" github-setup
  # assert
  rc_ok
  log_has "gh api -X PUT repos/demo/repo/rulesets/7 --input -"
  log_lacks "-X POST"
}

t_gh_no_required_check() {
  # arrange
  mk_gh_project workflow
  # act
  cm GH_RULESET_ID=7 "$BIN" github-setup
  # assert
  rc_ok
  log_lacks "/rulesets"
  log_lacks "-X POST"
  log_lacks "-X PUT"
  log_has "gh api -X PATCH repos/demo/repo"
}

t_gh_make_target() {
  # arrange
  printf 'sekret-token\n' >"$P/token.key"
  gh_ctx "COMMONS_GITHUB_SECRETS=TOKEN:token.key"
  # act
  cm make --no-print-directory github.setup
  # assert
  rc_ok
  log_has "gh secret set TOKEN -R demo/repo"
  log_has "gh api -X PATCH repos/demo/repo"
  never_leaks
}

mk_commons_clone() {
  CO="$C/commons-origin.git"
  CW="$C/commons-work"
  CL="$C/commons-clone"
  git init -q --bare -b main "$CO"
  git init -q -b main "$CW"
  mkdir -p "$CW/bin"
  cp -R "$REPO/bin" "$REPO/lib" "$REPO/make" "$REPO/compose" "$REPO/commons.ctx.example" "$CW/"
  ( cd "$CW" && git remote add origin "$CO" && git add . \
    && git -c user.name=t -c user.email=t@t commit -q -m one && git push -q origin main )
  git clone -q "$CO" "$CL"
  printf 'two\n' >"$CW/two.txt"
  ( cd "$CW" && git add two.txt && git -c user.name=t -c user.email=t@t commit -q -m two \
    && git tag v1 && git push -q origin main && git push -q origin v1 )
  git -C "$CL" rev-parse -q --verify refs/tags/v1 >/dev/null 2>&1 && diag "clone já tinha a tag v1"
  git -C "$CL" -c user.name=t -c user.email=t@t reset -q --hard HEAD~0
}

update_head_on_tag() {
  head=$(git -C "$CL" rev-parse HEAD)
  tag=$(git -C "$CL" rev-parse -q --verify 'refs/tags/v1^{commit}' 2>/dev/null)
  [ -n "$tag" ] || diag "clone sem a tag v1 após update"
  [ "$head" = "$tag" ] || diag "HEAD $head não está na tag v1 ($tag)"
}

t_update_bin() {
  # arrange
  mk_commons_clone
  # act
  cm "$CL/bin/commons" update
  # assert
  rc_ok
  update_head_on_tag
}

t_update_make() {
  # arrange
  mk_commons_clone
  rm "$P/.commons"
  ln -s "$CL" "$P/.commons"
  # act
  cm make --no-print-directory commons.update
  # assert
  rc_ok
  update_head_on_tag
}

t_update_uses_ctx_ref() {
  # arrange
  mk_commons_clone
  ( cd "$CW" && git tag v2 HEAD~1 && git push -q origin v2 )
  ctx_without COMMONS_REF
  printf 'COMMONS_REF=v2\n' >>"$P/commons.ctx"
  # act
  cm "$CL/bin/commons" update
  # assert
  rc_ok
  [ "$(git -C "$CL" rev-parse HEAD)" = "$(git -C "$CW" rev-parse 'v2^{commit}')" ] || diag "HEAD não está em v2"
}

t_help_lists_everything() {
  # arrange
  printf 'deploy: ## deploys the thing\n\t@true\n' >>"$P/Makefile"
  mkdir -p "$P/.project/make"
  printf 'extra: ## extra target\n\t@true\n' >"$P/.project/make/extra.mk"
  # act
  cm "$BIN" help
  # assert
  rc_ok
  grep -qF "<m>.lint" "$C/out" || diag "help sem o comando <m>.lint"
  grep -qF "up|down|logs" "$C/out" || diag "help sem up|down|logs"
  grep -qF "github.setup" "$C/out" || diag "help sem github.setup"
  grep -qF "commons.update" "$C/out" || diag "help sem commons.update"
  out_has "module core"
  out_has "module plain"
  out_has "  core.console"
  out_has "project"
  out_has "deploy  deploys the thing"
  out_has "extra  extra target"
}

t_help_without_ctx() {
  # arrange
  rm "$P/commons.ctx"
  # act
  cm "$BIN" help
  # assert
  rc_ok
  grep -qF "github.setup" "$C/out" || diag "help sem github.setup"
  out_has "module core"
}

t_help_empty_dir_without_ctx() {
  # arrange
  mkdir -p "$C/empty"
  # act
  ( cd "$C/empty" && "$BIN" help ) </dev/null >"$C/out" 2>"$C/err"
  RC=$?
  # assert
  rc_ok
  grep -qF "commands (make):" "$C/out" || diag "help sem cabeçalho"
}

t_help_flags() {
  # arrange
  # act
  cm "$BIN" --help
  # assert
  rc_ok
  grep -qF "commands (make):" "$C/out" || diag "--help sem cabeçalho"
}

t_make_default_goal_help() {
  # arrange
  # act
  cm make --no-print-directory
  # assert
  rc_ok
  grep -qF "commands (make):" "$C/out" || diag "make sem alvo não rodou help"
  out_has "  core.console"
}

t_make_help_target() {
  # arrange
  # act
  cm make --no-print-directory help
  # assert
  rc_ok
  out_has "module core"
}

run_case "compose: cada fragment passa em config -q" t_compose_config_valid
run_case "compose: database.yml conforme a tabela" t_compose_database_contract
run_case "compose: cache.yml conforme a tabela" t_compose_cache_contract
run_case "compose: mail.yml conforme a tabela" t_compose_mail_contract
run_case "compose: fragments sem projeto, ambiente nem DATABASE_URL" t_compose_fragments_are_generic
run_case "up: compose up -d --wait com COMPOSE_PROJECT_NAME" t_up_runs_compose_up_wait
run_case "down: --remove-orphans sem volumes" t_down_without_volumes
run_case "logs: compose logs -f" t_logs_follows
run_case "up: repassa argumentos" t_up_forwards_args
run_case "compose < 2.20 falha em up/down/logs" t_compose_old_version_fails
run_case "compose 1.x falha" t_compose_v1_version_fails
run_case "compose 2.20.0 é aceito" t_compose_min_version_ok
run_case "up sem docker falha com a mensagem de versão" t_compose_without_docker_fails
run_case "make up" t_make_up
run_case "make down" t_make_down
run_case "make logs" t_make_logs
run_case "init: cria Makefile, ctx, compose.yml e .gitignore" t_init_creates_files
run_case "init: roda conform e lista o que falta sem falhar" t_init_runs_conform_and_lists_missing
run_case "init: segunda execução não altera nenhum arquivo" t_init_second_run_changes_nothing
run_case "init: segunda execução preserva .gitignore existente" t_init_second_run_changes_nothing_with_user_files
run_case "init: Makefile próprio sem include fica intocado e avisa" t_init_existing_makefile_untouched
run_case "init: Makefile com include não avisa" t_init_existing_makefile_with_include_no_warning
run_case "init: sem modules.json gera services vazio" t_init_without_modules_json
run_case "init: módulos sem services geram services vazio" t_init_without_services
run_case "init: só postgres inclui só database" t_init_only_postgres
run_case "init: compose.yml existente intocado" t_init_existing_compose_untouched
run_case "init: commons.ctx existente intocado" t_init_existing_ctx_untouched
run_case "init: usa a raiz git quando commons está em subdiretório" t_init_outside_project_root_fails
run_case "init: projeto sob symlink" t_init_under_symlink
run_case "init: .gitignore sem newline final" t_init_gitignore_without_trailing_newline
run_case "init: compose.yml gerado é válido" t_init_generated_compose_is_valid
run_case "compose real: down mantém o volume database_data" t_compose_real_up_down_keeps_volume
run_case "github.setup: gh secret set por par com a chave no stdin" t_gh_secrets_set
run_case "github.setup: arquivo de secret ausente avisa e segue" t_gh_secrets_missing_file
run_case "github.setup: sem COMMONS_GITHUB_SECRETS não grava secret" t_gh_without_secrets_var
run_case "github.setup: PATCH de merge settings" t_gh_merge_patch
run_case "github.setup: ruleset adiado sem workflow na default" t_gh_ruleset_deferred
run_case "github.setup: ruleset criado com workflow na default" t_gh_ruleset_created
run_case "github.setup: segunda execução faz PUT no mesmo id" t_gh_ruleset_idempotent
run_case "github.setup: ruleset existente só recebe PUT" t_gh_ruleset_existing_put_only
run_case "github.setup: name parcial não conta como declarado" t_gh_ruleset_partial_name_deferred
run_case "github.setup: id de ruleset duplicado usa o primeiro" t_gh_ruleset_duplicate_ids
run_case "github.setup: sem COMMONS_REQUIRED_CHECK não toca rulesets" t_gh_no_required_check
run_case "make github.setup" t_gh_make_target
run_case "update: bin faz fetch --tags e checkout da tag" t_update_bin
run_case "update: make commons.update" t_update_make
run_case "update: usa COMMONS_REF do ctx" t_update_uses_ctx_ref
run_case "help: comandos, módulos, run/* e alvos ## do projeto" t_help_lists_everything
run_case "help: funciona sem commons.ctx" t_help_without_ctx
run_case "help: funciona em diretório vazio" t_help_empty_dir_without_ctx
run_case "help: --help" t_help_flags
run_case "make sem alvo executa help" t_make_default_goal_help
run_case "make help" t_make_help_target

printf '1..%s\n' "$N"
printf '# passed %s, failed %s\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
