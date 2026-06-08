#!/usr/bin/env bash
set -euo pipefail

# Runs as postgres on first boot. The hash flows through stdin so it stays
# out of argv and env.

pg_ctl -D /var/lib/pgsql/data -w start
hash=$(cat /run/post-startup/hash)
psql -h /run/postgresql -d postgres -v ON_ERROR_STOP=1 -tAqX -v hash="$hash" -f /usr/share/postgres/bootstrap.sql
pg_ctl -D /var/lib/pgsql/data -w stop
