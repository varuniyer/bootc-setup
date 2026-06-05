#!/usr/bin/env bash
set -euo pipefail

fetch_metadata() {
    curl -sf -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true
}

# webdav state (owned by caddy)
mkdir -p /var/lib/webdav/data
chown -R caddy:caddy /var/lib/webdav
chmod 0700 /var/lib/webdav /var/lib/webdav/data

# caddy logs + Caddyfile with hashed password from instance metadata
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy
chmod 0750 /var/log/caddy
CADDY_HASH=$(fetch_metadata caddy-hashed-password)
DESEC_TOKEN=$(fetch_metadata desec-token)
sed -e "s|CADDY_HASHED_PASSWORD|${CADDY_HASH}|" -e "s|DESEC_TOKEN|${DESEC_TOKEN}|" /usr/etc/caddy/Caddyfile > /etc/caddy/Caddyfile

# postgres: initdb on first boot, refresh configs every boot, delegate first-boot SQL to bootstrap.sh
need_bootstrap=
if [ ! -d /var/lib/pgsql/data/base ]; then
    postgresql-setup --initdb
    need_bootstrap=1
fi

cp /usr/share/postgres/*.conf /var/lib/pgsql/data/
chown postgres:postgres /var/lib/pgsql/data/*.conf
chmod 0600 /var/lib/pgsql/data/*.conf

if [ -n "$need_bootstrap" ]; then
    /usr/libexec/bootstrap.sh
fi
