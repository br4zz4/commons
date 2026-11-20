#!/bin/sh
set -eu
lib="$(ls -d /usr/local/bundle/ruby/*/bundler/gems/ward-rails-*/lib 2>/dev/null | head -n 1 || true)"
if [ -z "$lib" ]; then
  echo "[commons] ward-rails ausente, ignorando"
  exit 0
fi
mkdir -p /tmp/ward-root
ruby -I"$lib" -e 'require "ward/installer"; puts Ward::Installer.new(root: "/tmp/ward-root").install!'
mv /tmp/ward-root/bin/ward /usr/local/bin/ward
rm -rf /tmp/ward-root
/usr/local/bin/ward version
