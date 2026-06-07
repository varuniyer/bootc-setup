#!/usr/bin/env bash
set -euo pipefail

# Runs as postgres user from post-startup.sh, PG_HASH from caller's env.

pg_ctl -D /var/lib/pgsql/data -l /tmp/pg-init.log -w start
psql -d postgres -v ON_ERROR_STOP=1 -v "hash=$PG_HASH" -f /usr/share/postgres/bootstrap.sql
pg_ctl -D /var/lib/pgsql/data -w stop
