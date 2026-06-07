#!/bin/sh
set -eu

# Runs inside postgres:17-alpine. Reads plaintext password from stdin,
# outputs the SCRAM-SHA-256 verifier on stdout.

psql_set() {
    printf '\\set %s %s\n' "$1" "'$(printf %s "$2" | sed "s/'/''/g")'"
}

PW=$(cat)
DIR=$(mktemp -d)
initdb -D "$DIR" -A trust -U pg --no-instructions >/dev/null 2>&1
pg_ctl -D "$DIR" -o "-k /tmp -h ''" -l "$DIR/log" start -w >/dev/null
{
    psql_set pw "$PW"
    cat "$(dirname "$0")/hash.sql"
} | psql -h /tmp -U pg -d postgres -tAqX | tail -1
