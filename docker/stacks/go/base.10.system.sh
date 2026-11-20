#!/bin/sh
set -eu
apt-get update -qq
apt-get install --no-install-recommends -y ca-certificates curl tzdata
rm -rf /var/lib/apt/lists /var/cache/apt/archives
