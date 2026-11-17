#!/bin/sh
set -eu
exec ruby -Ilib -Itest test/hello_test.rb "$@"
