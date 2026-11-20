#!/bin/sh
set -eu
if [ -f bin/rails ]; then
  SECRET_KEY_BASE_DUMMY=1 \
    DATABASE_URL="postgres://postgres:postgres@localhost:5432/${PROJECT:-app}" \
    bundle exec rails assets:precompile
fi
mkdir -p tmp/pids tmp/cache log storage public/assets
useradd "$RELEASE_USER" --create-home --shell /bin/bash
chown -R "$RELEASE_USER:$RELEASE_USER" log storage tmp public/assets
[ ! -d db ] || chown -R "$RELEASE_USER:$RELEASE_USER" db
[ ! -d run ] || chmod +x run/*
[ ! -d bin ] || chmod +x bin/*
