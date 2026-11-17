#!/bin/sh

commons_info() { printf 'commons: %s\n' "$*" >&2; }
commons_warn() { printf 'commons: %s\n' "$*" >&2; }
commons_die() {
  printf 'commons: %s\n' "$*" >&2
  exit 1
}
