#!/usr/bin/env bash
set -euo pipefail

# Reads all deployment values from an env file (default: provision.env, override
# with $1), hashes the passwords locally, and creates the GCP instance with the
# results in metadata. post-startup-root.sh and bootstrap.sh fetch them on boot.
#
# Usage: ./provision.sh [env-file]

ENV_FILE="${1:-$(dirname "$0")/provision.env}"
# Plain source, not `set -a`, so secrets stay shell-local and never reach gcloud's env.
. "$ENV_FILE"

WORK=$(mktemp -d "$HOME/tmp/provision.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Passwords flow through stdin so they never hit argv or disk. The hashers strip
# the trailing newline, so the printf newline is not part of the hashed secret.
printf '%s\n' "$POSTGRES_PASSWORD" | podman run --rm -i --user postgres \
    -v "$PWD/hash-pg-password:/hash-pg-password:Z,ro" \
    docker.io/library/postgres:17-alpine /bin/sh /hash-pg-password/run.sh > "$WORK/pg-hash"
printf '%s\n' "$WEBDAV_PASSWORD" | caddy hash-password --algorithm argon2id > "$WORK/dav-hash"

# Tailscale OAuth client secret, used as an auth key by post-startup-tailscale.sh.
printf '%s' "$TS_AUTHKEY" > "$WORK/ts-authkey"

# MTA-STS policy body fetched once and baked into metadata.
curl -sSf "$MTA_STS_URL" > "$WORK/mta-sts-txt"

# Non-secret values go through files too so commas in REDIR_LIST survive --metadata.
printf '%s' "$ACME_EMAIL"      > "$WORK/acme-email"
printf '%s' "$DOMAIN"          > "$WORK/domain"
printf '%s' "$REDIR_LIST"      > "$WORK/redir-list"
printf '%s' "$WEBDAV_USERNAME" > "$WORK/dav-user"

gcloud compute instances create bootc \
    --zone="$ZONE" --machine-type=e2-small --image=bootc \
    --boot-disk-size=200GB --boot-disk-type=pd-standard --address=bootc-ip \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
    --no-service-account --no-scopes \
    --metadata-from-file "acme-email=$WORK/acme-email,domain=$WORK/domain,redir-list=$WORK/redir-list,mta-sts-txt=$WORK/mta-sts-txt,ts-authkey=$WORK/ts-authkey,postgres-experiments-scram=$WORK/pg-hash,webdav-username=$WORK/dav-user,webdav-password-hash=$WORK/dav-hash"

# Direct WireGuard path for Tailscale; without it, traffic falls back to DERP
# relays over outbound 443. Created once, shared by reprovisioned instances.
gcloud compute firewall-rules describe allow-tailscale-wireguard >/dev/null 2>&1 || \
    gcloud compute firewall-rules create allow-tailscale-wireguard \
        --direction=INGRESS --allow=udp:41641
