#!/bin/sh
set -eu

# Runs inside postgres:17-alpine. Expects PW env var with the plaintext password.
# Outputs the SCRAM-SHA-256 verifier on stdout.

ESC=$(printf '%s' "$PW" | sed "s/'/''/g")
DIR=$(mktemp -d)
initdb -D "$DIR" -A trust -U pg --no-instructions >/dev/null 2>&1
pg_ctl -D "$DIR" -o "-k /tmp -h ''" -l "$DIR/log" start -w >/dev/null
psql -h /tmp -U pg -d postgres -tAc "SET password_encryption='scram-sha-256'; CREATE ROLE x PASSWORD '$ESC'; SELECT rolpassword FROM pg_authid WHERE rolname='x'" | tail -1
