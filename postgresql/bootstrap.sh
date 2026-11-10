#!/usr/bin/env bash
set -euo pipefail

# Runs as postgres on first boot.

pg_ctl -D /var/lib/pgsql/data -w start
hash=$(cat /run/post-startup-postgresql/hash)
psql -h /run/postgresql -d postgres -v ON_ERROR_STOP=1 -tAqX -v hash="$hash" -f /usr/share/postgresql-setup/bootstrap.sql
pg_ctl -D /var/lib/pgsql/data -w stop
