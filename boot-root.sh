#!/usr/bin/env bash
set -euo pipefail

# caddy.service loads this file with EnvironmentFile=, and Caddy fills the Caddyfile's
# {$VAR} placeholders from that environment.
fetch=/opt/scripts/fetch_metadata.sh
for key in acme-email domain redir-list; do
    value=$($fetch "$key")
    name=${key//-/_}
    printf '%s=%s\n' "${name^^}" "$value"
done > /run/caddy/env

mkdir -p /run/caddy/mta-sts/.well-known
$fetch mta-sts-txt > /run/caddy/mta-sts/.well-known/mta-sts.txt
# Files under /run inherit var_run_t, which httpd_t (Caddy) cannot read.
chcon -R -t httpd_sys_content_t /run/caddy/mta-sts

( umask 077; $fetch webdav-htpasswd > /etc/webdav/htpasswd )

# containers/policy.json accepts image updates only when signed by this key.
$fetch sigstore-public-key > /etc/pki/containers/sigstore.pub

if [ ! -d "$PGDATA" ]; then
    $fetch postgresql-experiments-hash > "$RUNTIME_DIRECTORY/hash"
    chmod 0640 "$RUNTIME_DIRECTORY/hash"
fi
