#!/bin/sh
set -eu
apt-get update -qq
apt-get install --no-install-recommends -y build-essential git
rm -rf /var/lib/apt/lists /var/cache/apt/archives
