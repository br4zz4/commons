#!/bin/sh
set -eu
apt-get update -qq
apt-get install --no-install-recommends -y build-essential git pkgconf libpq-dev libyaml-dev
rm -rf /var/lib/apt/lists /var/cache/apt/archives
