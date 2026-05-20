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

# caddy logs
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy
chmod 0750 /var/log/caddy

# stunnel PSK: fetch from GCP metadata once and persist in /var
mkdir -p /var/lib/stunnel
chmod 0700 /var/lib/stunnel
if [ ! -f /var/lib/stunnel/psk.txt ]; then
    PSK=$(curl -sf -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/stunnel-psk" || true)
    if [ -n "$PSK" ]; then
        printf '%s\n' "$PSK" > /var/lib/stunnel/psk.txt
        chown root:root /var/lib/stunnel/psk.txt
        chmod 0600 /var/lib/stunnel/psk.txt
    fi
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
    runuser -u postgres -- pg_ctl -D /var/lib/pgsql/data -l /tmp/pg-init.log -w start
    runuser -u postgres -- psql -d postgres -v ON_ERROR_STOP=1 -f /usr/share/postgres/bootstrap.sql
    runuser -u postgres -- pg_ctl -D /var/lib/pgsql/data -w stop
fi
