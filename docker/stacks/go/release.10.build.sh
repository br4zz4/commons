#!/bin/sh
set -eu
go build -o /usr/local/bin/app ./...
useradd "$RELEASE_USER" --create-home --shell /bin/bash
