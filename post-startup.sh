#!/usr/bin/env bash
set -euo pipefail

# webdav state
mkdir -p /var/lib/webdav/data /var/lib/webdav/lock
chown -R apache:apache /var/lib/webdav
chmod 0700 /var/lib/webdav /var/lib/webdav/data /var/lib/webdav/lock
chcon -Rt httpd_sys_rw_content_t /var/lib/webdav
if [ ! -e /var/lib/webdav/lock/lockdb ]; then
    touch /var/lib/webdav/lock/lockdb
    chown apache:apache /var/lib/webdav/lock/lockdb
    chmod 0600 /var/lib/webdav/lock/lockdb
fi

# caddy logs + Caddyfile with hashed password from /var
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy
chmod 0750 /var/log/caddy
if [ -f /var/lib/caddy/hashed-password ]; then
    CADDY_HASH=$(cat /var/lib/caddy/hashed-password)
    sed "s|CADDY_HASHED_PASSWORD|${CADDY_HASH}|" /usr/etc/caddy/Caddyfile > /etc/caddy/Caddyfile
fi

# stunnel PSK permissions
mkdir -p /var/lib/stunnel
chmod 0700 /var/lib/stunnel
if [ -f /var/lib/stunnel/psk.txt ]; then
    chown root:root /var/lib/stunnel/psk.txt
    chmod 0600 /var/lib/stunnel/psk.txt
fi

# postgres: initdb + bootstrap role/db on first boot, refresh configs every boot
need_bootstrap=
if [ ! -d /var/lib/pgsql/data/base ]; then
    postgresql-setup --initdb
    need_bootstrap=1
fi

cp /usr/share/postgres/*.conf /var/lib/pgsql/data/
chown postgres:postgres /var/lib/pgsql/data/*.conf
chmod 0600 /var/lib/pgsql/data/*.conf

if [ -n "$need_bootstrap" ]; then
    runuser -u postgres -- bash -c '
        pg_ctl -D /var/lib/pgsql/data -l /tmp/pg-init.log -w start &&
        psql -d postgres -v ON_ERROR_STOP=1 -f /usr/share/postgres/bootstrap.sql &&
        pg_ctl -D /var/lib/pgsql/data -w stop
    '
fi
