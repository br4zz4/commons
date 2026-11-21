#!/bin/sh
set -eu
if [ "${DEPS_ENV:-dev}" = "release" ]; then
  BUNDLE_WITHOUT="development:test"
  export BUNDLE_WITHOUT
fi
final_path="$BUNDLE_PATH"
BUNDLE_PATH=/cache/deps/bundle
export BUNDLE_PATH
bundle install
bundle clean --force
rm -rf "$BUNDLE_PATH"/ruby/*/cache
mkdir -p "$final_path"
cp -a "$BUNDLE_PATH"/. "$final_path"/
