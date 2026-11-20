#!/bin/sh
set -eu
mix local.hex --force
mix local.rebar --force
if [ "${DEPS_ENV:-dev}" = "release" ]; then
  MIX_ENV=prod mix deps.get --only prod
else
  mix deps.get
fi
