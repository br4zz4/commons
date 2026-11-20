#!/bin/sh
{
  printf 'MODULE=%s\n' "${MODULE-unset}"
  printf 'ENVIRONMENT=%s\n' "${ENVIRONMENT-unset}"
  printf 'CI_CACHE_DIR=%s\n' "${CI_CACHE_DIR-unset}"
  printf 'TAG=%s\n' "${TAG-unset}"
  printf 'ENV=%s\n' "${ENV-unset}"
  printf 'PWD=%s\n' "$(pwd -P)"
  printf 'ARGS=%s\n' "$*"
  printf 'WARD_CONTEXT=%s\n' "${WARD_CONTEXT-unset}"
} >"$HOOK_OUT"
