#!/usr/bin/env bash
set -euo pipefail

# First-boot postgres bootstrap: runs roles/db creation SQL and applies the
# experiments role's password from instance metadata. Assumes /var/lib/pgsql/data
# is already initdb'd and configs are in place.

PG_HASH=$(fetch_metadata postgres-experiments-scram)
INIT_SQL=$(mktemp)
trap 'rm -f "$INIT_SQL"' EXIT
cat /usr/share/postgres/bootstrap.sql > "$INIT_SQL"
# Postgres stores SCRAM-SHA-256$... strings verbatim.
[ -n "$PG_HASH" ] && printf "ALTER ROLE experiments PASSWORD '%s';\n" "$PG_HASH" >> "$INIT_SQL"
chown postgres:postgres "$INIT_SQL"
chmod 0600 "$INIT_SQL"

runuser -u postgres -- bash -c "
    pg_ctl -D /var/lib/pgsql/data -l /tmp/pg-init.log -w start &&
    psql -d postgres -v ON_ERROR_STOP=1 -f '$INIT_SQL' &&
    pg_ctl -D /var/lib/pgsql/data -w stop
"
