#!/bin/sh
# Install reproducible public ADBC drivers into a private project directory.
set -eu
cd "$(dirname "$0")/.."
export ADBC_DRIVER_PATH="$PWD/.build/quality-drivers/config/adbc/drivers"
mkdir -p "$ADBC_DRIVER_PATH"
for driver in 'postgresql=1.13.0' 'mysql=0.7.1' 'sqlite=1.13.0' 'duckdb=2.0.0'; do
    dbc install "$driver"
done
