#!/usr/bin/env bash
set -euo pipefail

# Caddy fills the Caddyfile's {$VAR} placeholders from this env file at parse.
f=/opt/scripts/fetch_metadata.sh
printf '%s\n' \
    "ACME_EMAIL=$($f acme-email)" \
    "DOMAIN=$($f domain)" \
    "REDIR_LIST=\"$($f redir-list)\"" > /run/caddy/env

mkdir -p /run/caddy/mta-sts/.well-known
$f mta-sts-txt > /run/caddy/mta-sts/.well-known/mta-sts.txt

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
