#!/bin/sh
set -eu

# Reads the plaintext password from stdin and writes its SCRAM-SHA-256 hash to stdout.

PGDATA=$(mktemp -d)
export PGDATA PGHOST=/tmp
initdb -A trust >/dev/null 2>&1
pg_ctl -o "-k $PGHOST -h ''" start -w >/dev/null
psql -tAqX -v ON_ERROR_STOP=1 -f "$(dirname "$0")/hash.sql"
