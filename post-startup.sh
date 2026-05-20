#!/usr/bin/env bash
set -euo pipefail

fetch_secret() {
    local project token
    project=$(curl -sf -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/project/project-id") || return 1
    token=$(curl -sf -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'],end='')") || return 1
    curl -sf \
        -H "Authorization: Bearer $token" \
        "https://secretmanager.googleapis.com/v1/projects/${project}/secrets/$1/versions/latest:access" \
        | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['payload']['data']).decode(),end='')" || return 1
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

# caddy logs + Caddyfile with hashed password from Secret Manager
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy
chmod 0750 /var/log/caddy
CADDY_HASH=$(fetch_secret caddy-hashed-password || true)
if [ -n "$CADDY_HASH" ]; then
    sed "s|CADDY_HASHED_PASSWORD|${CADDY_HASH}|" /usr/etc/caddy/Caddyfile > /etc/caddy/Caddyfile
fi

# stunnel PSK: fetch from Secret Manager once and persist in /var
mkdir -p /var/lib/stunnel
chmod 0700 /var/lib/stunnel
if [ ! -f /var/lib/stunnel/psk.txt ]; then
    PSK=$(fetch_secret stunnel-psk || true)
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
    runuser -u postgres -- bash -c '
        pg_ctl -D /var/lib/pgsql/data -l /tmp/pg-init.log -w start &&
        psql -d postgres -v ON_ERROR_STOP=1 -f /usr/share/postgres/bootstrap.sql &&
        pg_ctl -D /var/lib/pgsql/data -w stop
    '
fi
