#!/bin/sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
BIN="$REPO/bin/commons"
MODPY="$REPO/lib/modules.py"
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT INT TERM
ORIG_PATH="$PATH"

unset ENV ENVIRONMENT CONFIRM GITHUB_ACTIONS TAG FAKE_WARD_EMPTY FAKE_WARD_NOKEY

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

printf '1..%s\n' "$N"
printf '# passed %s, failed %s\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
