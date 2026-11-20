#!/bin/sh
set -eu
apt-get update -qq
apt-get install --no-install-recommends -y \
  bash curl tzdata libpq5 libyaml-0-2 libjemalloc2 postgresql-client
rm -rf /var/lib/apt/lists /var/cache/apt/archives
jemalloc="$(dpkg -L libjemalloc2 | grep -m1 '/libjemalloc\.so\.2$')"
ln -s "$jemalloc" /usr/local/lib/libjemalloc.so.2
test -e /usr/local/lib/libjemalloc.so.2
