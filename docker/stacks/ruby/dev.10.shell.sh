#!/bin/sh
set -eu
apt-get update -qq
apt-get install --no-install-recommends -y tmux zsh
rm -rf /var/lib/apt/lists /var/cache/apt/archives
