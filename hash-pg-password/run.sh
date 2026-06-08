#!/bin/sh
set -eu

# Runs inside postgres:17-alpine. Reads plaintext password from stdin,
# outputs the SCRAM-SHA-256 verifier on stdout.

PW=$(cat)
DIR=$(mktemp -d)
initdb -D "$DIR" -A trust -U pg --no-instructions >/dev/null 2>&1
pg_ctl -D "$DIR" -o "-k /tmp -h ''" start -w >/dev/null
{
    printf %s "$PW" | "$(dirname "$0")/psql_set.sh" pw
    cat "$(dirname "$0")/hash.sql"
} | psql -h /tmp -U pg -d postgres -tAqX | tail -1
