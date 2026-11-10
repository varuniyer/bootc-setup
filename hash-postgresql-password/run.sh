#!/bin/sh
set -eu

# Reads the plaintext password from stdin and writes its SCRAM-SHA-256 hash to stdout.

DIR=$(mktemp -d)
initdb -D "$DIR" -A trust >/dev/null 2>&1
pg_ctl -D "$DIR" -o "-k /tmp -h ''" start -w >/dev/null
psql -h /tmp -tAqX -v ON_ERROR_STOP=1 -f "$(dirname "$0")/hash.sql"
