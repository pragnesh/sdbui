#!/usr/bin/env bash
# Requires a GTK display (or xvfb-run) and GTK4 development libraries.
set -euo pipefail
cd "$(dirname "$0")/.."
binary=$(mktemp /tmp/sdbui-values-test.XXXXXX)
trap 'rm -f "$binary"' EXIT
cc -Wall -Wextra -Werror -I Sources/CResultValue/include \
  $(pkg-config --cflags gtk4) Tests/CResultValueTests/interaction.c \
  Sources/CResultValue/result_value.c Sources/CResultValue/sql_editor.c $(pkg-config --libs gtk4) -o "$binary"
"$binary"
