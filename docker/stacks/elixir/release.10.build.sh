#!/bin/sh
set -eu
mix deps.compile
mix compile
useradd "$RELEASE_USER" --create-home --shell /bin/bash
chown -R "$RELEASE_USER:$RELEASE_USER" /source
