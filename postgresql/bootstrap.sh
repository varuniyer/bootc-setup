#!/usr/bin/env bash
set -euo pipefail

# Runs as postgres until a bootstrap succeeds. Only the final rename creates $PGDATA,
# so after a failed attempt boot-root.sh fetches the hash again and the next boot retries.
staging=$PGDATA.staging
rm -rf "$staging"
initdb -D "$staging"
# initdb's pg_hba.conf trusts every local connection, so the temporary server starts with the shipped configs.
cp /usr/share/boot-postgresql/*.conf "$staging"/
pg_ctl -D "$staging" -w start
psql -d postgres -v ON_ERROR_STOP=1 -tAqX -f /usr/share/boot-postgresql/bootstrap.sql < /run/boot-postgresql/hash
pg_ctl -D "$staging" -w stop
mv -T "$staging" "$PGDATA"
