#!/bin/sh

commons_load_ctx() {
  [ -f "$COMMONS_ROOT/commons.ctx" ] || commons_die "sem commons.ctx em $COMMONS_ROOT"
  # shellcheck disable=SC1091
  . "$COMMONS_ROOT/commons.ctx"
  for key in COMMONS_PROJECT COMMONS_ENVS COMMONS_ENV_LOCAL COMMONS_ENV_CHECK COMMONS_ENV_REMOTE COMMONS_REF; do
    eval "value=\${$key-}"
    [ -n "$value" ] || commons_die "commons.ctx sem $key"
  done
  if [ -n "${COMMONS_VAULT-}" ]; then
    [ -n "${COMMONS_SCOPE-}" ] || commons_die "commons.ctx sem COMMONS_SCOPE"
  fi
  if [ -n "${COMMONS_RESTRICTED_VAULT-}" ] && [ -z "${COMMONS_RESTRICTED_ENVS-}" ]; then
    commons_die "commons.ctx sem COMMONS_RESTRICTED_ENVS"
  fi
  for key in COMMONS_ENV_LOCAL COMMONS_ENV_CHECK COMMONS_ENV_REMOTE; do
    eval "value=\${$key}"
    commons_env_valid "$value" || commons_die "ambiente $value fora de COMMONS_ENVS"
  done
}

commons_in_list() {
  case ",$2," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

commons_env_valid() {
  commons_in_list "$1" "$COMMONS_ENVS"
}

commons_resolve_env() {
  chosen="${COMMONS_ENV_ARG:-${ENVIRONMENT:-$1}}"
  commons_env_valid "$chosen" || commons_die "ambiente $chosen fora de COMMONS_ENVS"
  COMMONS_CURRENT_ENV="$chosen"
}

commons_is_restricted() {
  [ -n "${COMMONS_RESTRICTED_ENVS-}" ] && commons_in_list "$1" "$COMMONS_RESTRICTED_ENVS"
}

commons_guard() {
  commons_is_restricted "$COMMONS_CURRENT_ENV" || return 0
  [ "${GITHUB_ACTIONS-}" = "true" ] && return 0
  if [ -n "${CONFIRM-}" ]; then
    [ "$CONFIRM" = "$COMMONS_PROJECT" ] || commons_die "CONFIRM não confere com $COMMONS_PROJECT"
    return 0
  fi
  if [ -t 0 ] && [ -t 2 ]; then
    printf 'commons: ambiente %s. Digite %s para confirmar: ' "$COMMONS_CURRENT_ENV" "$COMMONS_PROJECT" >&2
    read -r answer
    [ "$answer" = "$COMMONS_PROJECT" ] || commons_die "confirmação não confere"
    return 0
  fi
  commons_die "ambiente $COMMONS_CURRENT_ENV exige CONFIRM=$COMMONS_PROJECT"
}

commons_vault_for_env() {
  if commons_is_restricted "$1" && [ -n "${COMMONS_RESTRICTED_VAULT-}" ]; then
    printf '%s\n' "$COMMONS_RESTRICTED_VAULT"
  else
    printf '%s\n' "${COMMONS_VAULT-}"
  fi
}

commons_scope() {
  vault=$(commons_vault_for_env "$COMMONS_CURRENT_ENV")
  [ -n "$vault" ] || return 0
  printf '%s\n' "$COMMONS_SCOPE" | sed -e "s|{vault}|$vault|g" -e "s|{module}|$1|g" -e "s|{side}|$2|g" -e "s|{env}|$COMMONS_CURRENT_ENV|g"
}

commons_check_scope() {
  scope="$1"
  vault=$(commons_vault_for_env "$COMMONS_CURRENT_ENV")
  err=$(mktemp)
  out=$(ward secrets --json "$scope" 2>"$err") && status=0 || status=$?
  if [ "$status" -ne 0 ]; then
    if grep -qi 'AI mode' "$err"; then
      rm -f "$err"
      commons_die "o ward recusou ler $scope: ele roda em modo de agente (rode fora do agente)"
    elif grep -qiE 'missing key|no encryption key|cannot decrypt|decrypt|WARD_KEY' "$err"; then
      rm -f "$err"
      commons_die "sem acesso ao vault $vault (falta a chave)"
    fi
    out=""
  fi
  rm -f "$err"
  [ -n "$out" ] && [ "$out" != "{}" ]
}

commons_scope_names() {
  ward secrets --json "$1" | python3 -I -c 'import json, sys
for name in json.load(sys.stdin):
    print(name)'
}

commons_scope_missing() {
  ward secrets --json "$1" | python3 -I -c 'import json, sys
names = [name for name, value in json.load(sys.stdin).items() if value in ("", None, "CHANGE_ME")]
print(" ".join(names))'
}

commons_dir() {
  dir=$(python3 -I "$COMMONS_HOME/lib/modules.py" "$COMMONS_ROOT" dir "$1" "$2") || exit 1
  printf '%s\n' "$COMMONS_ROOT/$dir"
}

commons_validate_module() {
  python3 -I "$COMMONS_HOME/lib/modules.py" "$COMMONS_ROOT" dir "$1" code >/dev/null || exit 1
}

commons_run_in() {
  dir="$1"
  shift
  [ -f "$dir/mise.toml" ] || commons_die "$dir sem mise.toml"
  if [ -n "$COMMONS_SCOPES" ]; then
    # shellcheck disable=SC2086
    set -- ward exec $COMMONS_SCOPES -- mise exec -C "$dir" -- sh -c 'cd "$0" && exec "$@"' "$dir" "$@"
  else
    set -- mise exec -C "$dir" -- sh -c 'cd "$0" && exec "$@"' "$dir" "$@"
  fi
  exec "$@"
}

commons_prepare() {
  module="$1"
  side="$2"
  default_env="$3"
  commons_validate_module "$module"
  commons_resolve_env "$default_env"
  commons_guard
  COMMONS_SCOPES=""
  if [ -n "$(commons_vault_for_env "$COMMONS_CURRENT_ENV")" ]; then
    for current_side in $side; do
      scope=$(commons_scope "$module" "$current_side")
      if commons_check_scope "$scope"; then
        COMMONS_SCOPES="$COMMONS_SCOPES $scope"
      else
        commons_warn "escopo $scope vazio"
      fi
    done
  fi
  MODULE="$module"
  ENVIRONMENT="$COMMONS_CURRENT_ENV"
  TAG="${TAG-}"
  export MODULE ENVIRONMENT TAG
}

commons_check_collision() {
  code_scope="$1"
  infra_scope="$2"
  names_code=$(commons_scope_names "$code_scope")
  names_infra=$(commons_scope_names "$infra_scope")
  for name in $names_code; do
    for other in $names_infra; do
      [ "$name" = "$other" ] && commons_die "$name existe em $code_scope e $infra_scope"
    done
  done
  return 0
}

commons_relative() {
  printf '%s\n' "${1#"$COMMONS_ROOT"/}"
}
