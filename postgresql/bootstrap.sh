#!/usr/bin/env bash
set -euo pipefail

# $PGDATA appears only at the final rename, so boot-root.sh's first-boot test stays true after a failed attempt.
staging=$PGDATA.staging
rm -rf "$staging"
initdb -D "$staging"
# initdb's pg_hba.conf trusts every local connection, so the temporary server starts with the shipped configs.
pg_ctl -D "$staging" -o "-c config_file=/usr/share/boot-postgresql/postgresql.conf" -w start
psql -d postgres -v ON_ERROR_STOP=1 -qX -f /usr/share/boot-postgresql/bootstrap.sql
pg_ctl -D "$staging" -w stop
mv -T "$staging" "$PGDATA"
