#!/usr/bin/env bash
set -euo pipefail

# Runs as postgres on first boot. The hash flows through stdin so it stays
# out of argv and env.

psql_set() {
    # Emit "\set var 'value'" with single quotes doubled for SQL safety.
    printf '\\set %s %s\n' "$1" "'$(printf %s "$2" | sed "s/'/''/g")'"
}

pg_ctl -D /var/lib/pgsql/data -l /tmp/pg-init.log -w start
{
    psql_set hash "$(cat /run/post-startup/hash)"
    cat /usr/share/postgres/bootstrap.sql
} | psql -h /run/postgresql -d postgres -v ON_ERROR_STOP=1 -tAqX
pg_ctl -D /var/lib/pgsql/data -w stop
