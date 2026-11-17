#!/bin/sh

commons_conform_fail() {
  printf 'commons: conform: %s\n' "$*" >&2
  COMMONS_CONFORM_FAILED=1
}

commons_conform_ctx() {
  if ! (commons_load_ctx) 2>"${TMPDIR:-/tmp}/commons-ctx.$$"; then
    message=$(sed -e 's/^commons: //' "${TMPDIR:-/tmp}/commons-ctx.$$")
    commons_conform_fail "commons.ctx: $message"
    rm -f "${TMPDIR:-/tmp}/commons-ctx.$$"
    return 1
  fi
  rm -f "${TMPDIR:-/tmp}/commons-ctx.$$"
}

commons_conform_module() {
  module="$1"
  code=$(commons_dir "$module" code)
  infra=$(commons_dir "$module" infra)
  if [ -d "$code/run" ]; then
    for script in "$code"/run/*; do
      [ -e "$script" ] || continue
      name=$(basename "$script")
      case " $COMMONS_RESERVED_NAMES " in
        *" $name "*) commons_conform_fail "$(commons_relative "$script"): nome reservado" ;;
      esac
    done
  fi
  if [ -d "$infra/ops" ]; then
    for script in "$infra"/ops/*; do
      [ -e "$script" ] || continue
      case "$(basename "$script")" in
        remote.sh | secrets.sh) ;;
        *) commons_conform_fail "$(commons_relative "$script"): fora do vocabulário de ops" ;;
      esac
    done
  fi
}

commons_conform_compose() {
  [ -f "$COMMONS_ROOT/compose.yml" ] || return 0
  grep -E '^[[:space:]]*-[[:space:]]+[^[:space:]]*/compose/[A-Za-z0-9_.-]+\.yml[[:space:]]*$' "$COMMONS_ROOT/compose.yml" |
    sed -e 's/^[[:space:]]*-[[:space:]]*//' -e 's/[[:space:]]*$//' |
    while IFS= read -r path; do
      [ -f "$COMMONS_ROOT/$path" ] || printf '%s\n' "$path"
    done > "${TMPDIR:-/tmp}/commons-compose.$$"
  while IFS= read -r path; do
    commons_conform_fail "compose.yml: $path não existe"
  done < "${TMPDIR:-/tmp}/commons-compose.$$"
  rm -f "${TMPDIR:-/tmp}/commons-compose.$$"
}

commons_conform() {
  COMMONS_CONFORM_FAILED=0
  COMMONS_RESERVED_NAMES="lint audit test build validate plan shell db keys remote secrets"
  commons_conform_ctx || true
  if ! modules=$(python3 -I "$COMMONS_HOME/lib/modules.py" "$COMMONS_ROOT" list 2>"${TMPDIR:-/tmp}/commons-mod.$$"); then
    commons_conform_fail ".github/modules.json: $(sed -e 's/^commons: //' "${TMPDIR:-/tmp}/commons-mod.$$")"
    modules=""
  fi
  rm -f "${TMPDIR:-/tmp}/commons-mod.$$"
  for module in $modules; do
    commons_conform_module "$module"
  done
  commons_conform_compose
  [ "$COMMONS_CONFORM_FAILED" -eq 0 ] || exit 1
  commons_info "conform ok"
}
