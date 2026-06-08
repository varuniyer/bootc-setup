#!/bin/sh
set -eu

# Runs inside postgres:17-alpine. Reads plaintext password from stdin,
# outputs the SCRAM-SHA-256 verifier on stdout.

DIR=$(mktemp -d)
initdb -D "$DIR" -A trust -U pg --no-instructions >/dev/null 2>&1
pg_ctl -D "$DIR" -o "-k /tmp -h ''" start -w >/dev/null
pw=$(cat)
psql -h /tmp -U pg -d postgres -tAqX -v ON_ERROR_STOP=1 -v pw="$pw" -f "$(dirname "$0")/hash.sql" | tail -1
