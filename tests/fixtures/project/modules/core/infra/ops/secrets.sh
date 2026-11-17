#!/bin/sh
{
  printf 'HOOK=%s\n' "$(basename "$0")"
  printf 'MODULE=%s\n' "${MODULE-unset}"
  printf 'ENVIRONMENT=%s\n' "${ENVIRONMENT-unset}"
  printf 'PWD=%s\n' "$(pwd -P)"
  printf 'ARGS=%s\n' "$*"
  printf 'A=%s\n' "${A-unset}"
  printf 'I=%s\n' "${I-unset}"
  printf 'COMMONS_SECRET_KEYS=%s\n' "${COMMONS_SECRET_KEYS-unset}"
} >"$HOOK_OUT"
