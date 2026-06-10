#!/usr/bin/env bash
set -euo pipefail

# Caddyfile rendered from the /usr/etc template; `>` truncates /etc/caddy/Caddyfile
# in place, preserving the build-time root:caddy 0640 owner/mode.
f=/opt/scripts/fetch_metadata.sh \
ACME_EMAIL=$($f acme-email) \
DOMAIN=$($f domain) \
REDIR_LIST=$($f redir-list) \
MTA_STS_TXT=$($f mta-sts-txt) \
envsubst '$ACME_EMAIL $DOMAIN $REDIR_LIST $MTA_STS_TXT' < /usr/etc/caddy/Caddyfile > /etc/caddy/Caddyfile

# RuntimeDirectory creates the dir as root:root 0750; tighten to root:creds so
# postgres (via creds membership) can traverse it but the world cannot.
chgrp creds /run/post-startup-postgresql

( umask 077; /opt/scripts/fetch_metadata.sh webdav-htpasswd > /etc/rclone/webdav.htpasswd )

# Postgres hash on first boot only. chgrp creds works without CAP_CHOWN because root
# is in the creds group (set in setup.sh); postgres reads via creds membership.
if [ ! -d /var/lib/pgsql/data/base ]; then
    /opt/scripts/fetch_metadata.sh postgres-experiments-scram > /run/post-startup-postgresql/hash
    chgrp creds /run/post-startup-postgresql/hash
    chmod 0640 /run/post-startup-postgresql/hash
fi
