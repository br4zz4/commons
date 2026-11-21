#!/bin/sh
set -eu
if [ -f bin/rails ] && bundle exec bootsnap --version >/dev/null 2>&1; then
  bundle exec bootsnap precompile --gemfile app/ lib/
fi
