#!/bin/sh
set -eu
if [ "${DEPS_ENV:-dev}" = "release" ]; then
  BUNDLE_WITHOUT="development:test"
  export BUNDLE_WITHOUT
fi
bundle install
rm -rf /usr/local/bundle/ruby/*/cache
