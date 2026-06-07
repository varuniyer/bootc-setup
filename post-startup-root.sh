#!/usr/bin/env bash
set -euo pipefail

# Caddyfile rendered from the /usr/etc template; `>` truncates /etc/caddy/Caddyfile
# in place, preserving the build-time root:caddy 0640 owner/mode.
CADDY_HASHED_PASSWORD=$(/opt/scripts/fetch_metadata.sh caddy-hashed-password) \
POSTGRES_IP_ALLOWLIST=$(/opt/scripts/fetch_metadata.sh postgres-ip-allowlist) \
envsubst '$CADDY_HASHED_PASSWORD $POSTGRES_IP_ALLOWLIST' < /usr/etc/caddy/Caddyfile > /etc/caddy/Caddyfile

# RuntimeDirectory creates the dir as root:root 0750; tighten to root:creds so
# postgres (via creds membership) can traverse it but the world cannot.
chgrp creds /run/post-startup

# Postgres hash on first boot only. chgrp creds works without CAP_CHOWN because root
# is in the creds group (set in setup.sh); postgres reads via creds membership.
if [ ! -d /var/lib/pgsql/data/base ]; then
    /opt/scripts/fetch_metadata.sh postgres-experiments-scram > /run/post-startup/hash
    chgrp creds /run/post-startup/hash
    chmod 0640 /run/post-startup/hash
fi
