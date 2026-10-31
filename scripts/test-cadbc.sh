#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_binary=$(mktemp /tmp/sdbui-cadbc-test.XXXXXX)
trap 'rm -f "$test_binary"' EXIT
"${CC:-cc}" -Wall -Wextra -Werror -I Sources/CADBC/include \
    Tests/CADBCStreamTests/lifetime.c -ldl -o "$test_binary"
"$test_binary"
