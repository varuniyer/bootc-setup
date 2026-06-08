#!/usr/bin/env bash
set -euo pipefail

# Runs as postgres on first boot. The hash flows through stdin so it stays
# out of argv and env.

pg_ctl -D /var/lib/pgsql/data -w start
{
    /opt/scripts/psql_set.sh hash < /run/post-startup/hash
    cat /usr/share/postgres/bootstrap.sql
} | psql -h /run/postgresql -d postgres -v ON_ERROR_STOP=1 -tAqX
pg_ctl -D /var/lib/pgsql/data -w stop
