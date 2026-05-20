#!/usr/bin/env bash
set -euo pipefail

# webdav state
install -d -o apache -g apache -m 0700 /var/lib/webdav /var/lib/webdav/data /var/lib/webdav/lock
[ -e /var/lib/webdav/lock/lockdb ] || install -o apache -g apache -m 0600 /dev/null /var/lib/webdav/lock/lockdb

# caddy logs
install -d -o caddy -g caddy -m 0750 /var/log/caddy

# postgres: initdb + bootstrap role/db on first boot, refresh configs every boot
need_bootstrap=
if [ ! -d /var/lib/pgsql/data/base ]; then
    postgresql-setup --initdb
    need_bootstrap=1
fi

install -o postgres -g postgres -m 0600 /usr/share/postgres/postgresql.conf /var/lib/pgsql/data/postgresql.conf
install -o postgres -g postgres -m 0600 /usr/share/postgres/pg_hba.conf      /var/lib/pgsql/data/pg_hba.conf

if [ -n "$need_bootstrap" ]; then
    runuser -u postgres -- pg_ctl -D /var/lib/pgsql/data -l /tmp/pg-init.log -w start
    runuser -u postgres -- psql -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE experiments LOGIN;
CREATE DATABASE experiments OWNER experiments;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
SQL
    runuser -u postgres -- pg_ctl -D /var/lib/pgsql/data -w stop
fi
