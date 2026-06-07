#!/usr/bin/env bash
set -euo pipefail

# Runs as postgres from post-startup.sh on first boot. Reads the SCRAM
# verifier from /run/post-startup/hash and feeds it to psql via stdin so it
# never appears in argv or env.

pg_ctl -D /var/lib/pgsql/data -l /tmp/pg-init.log -w start
{
    printf '\\set hash %s\n' "'$(sed "s/'/''/g" /run/post-startup/hash)'"
    cat /usr/share/postgres/bootstrap.sql
} | psql -h /run/postgresql -d postgres -v ON_ERROR_STOP=1 -tAqX
pg_ctl -D /var/lib/pgsql/data -w stop
