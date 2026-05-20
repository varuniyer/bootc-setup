#!/usr/bin/env bash
set -euo pipefail

fetch_metadata() {
    curl -sf -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true
}

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

# caddy logs + Caddyfile with hashed password from instance metadata
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy
chmod 0750 /var/log/caddy
CADDY_HASH=$(fetch_metadata caddy-hashed-password)
if [ -n "$CADDY_HASH" ]; then
    sed "s|CADDY_HASHED_PASSWORD|${CADDY_HASH}|" /usr/etc/caddy/Caddyfile > /etc/caddy/Caddyfile
fi

# stunnel PSK: fetch from instance metadata once and persist in /var;
# copy to /etc/stunnel/psk.txt each boot so stunnel can read it
mkdir -p /var/lib/stunnel
chmod 0700 /var/lib/stunnel
if [ ! -f /var/lib/stunnel/psk.txt ]; then
    PSK=$(fetch_metadata stunnel-psk)
    if [ -n "$PSK" ]; then
        printf '%s\n' "$PSK" > /var/lib/stunnel/psk.txt
        chown root:root /var/lib/stunnel/psk.txt
        chmod 0600 /var/lib/stunnel/psk.txt
    fi
fi
if [ -f /var/lib/stunnel/psk.txt ]; then
    cp /var/lib/stunnel/psk.txt /etc/stunnel/psk.txt
    chmod 0600 /etc/stunnel/psk.txt
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
