#!/usr/bin/env bash
set -euo pipefail

# webdav state (owned by caddy)
mkdir -p /var/lib/webdav/data
chown -R caddy:caddy /var/lib/webdav
chmod 0700 /var/lib/webdav /var/lib/webdav/data

# Caddyfile with hashed password from instance metadata
export CADDY_HASHED_PASSWORD=$(fetch_metadata caddy-hashed-password)
export POSTGRES_IP_ALLOWLIST=$(fetch_metadata postgres-ip-allowlist)
if [ -n "$CADDY_HASHED_PASSWORD" ] || [ -n "$POSTGRES_IP_ALLOWLIST" ]; then
    envsubst '$CADDY_HASHED_PASSWORD $POSTGRES_IP_ALLOWLIST' < /usr/etc/caddy/Caddyfile > /etc/caddy/Caddyfile
    chown root:caddy /etc/caddy/Caddyfile
    chmod 0640 /etc/caddy/Caddyfile
fi

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
