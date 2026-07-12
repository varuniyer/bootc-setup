#!/usr/bin/env bash
set -euo pipefail

# Hashes the .env passwords locally and creates the GCP instance with the
# results in metadata. Usage: dotenvx run -- ./provision.sh

# Passwords flow through stdin so they never hit argv or disk. The hashers strip
# the trailing newline, so the printf newline is not part of the hashed secret.
hash=$(printf '%s\n' "$POSTGRES_PASSWORD" | podman run --rm -i --user postgres \
    -v "$PWD/hash-pg-password:/hash-pg-password:Z,ro" \
    docker.io/library/postgres:17-alpine /bin/sh /hash-pg-password/run.sh)
htpasswd=$(printf '%s' "$WEBDAV_PASSWORD" | podman run --rm -i docker.io/library/alpine:latest \
    sh -c 'apk add -q --no-cache apache2-utils >&2 && htpasswd -niB "$1"' \
    hash "$WEBDAV_USERNAME")

# MTA-STS policy body fetched once and baked into metadata.
mtasts=$(curl -sSf "$MTA_STS_URL")

gcloud compute instances create bootc \
    --zone="$ZONE" --machine-type="$MACHINE_TYPE" --image=bootc \
    --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" --address=bootc-ip \
    --shielded-secure-boot --shielded-vtpm --no-service-account --no-scopes \
    --metadata "^|^acme-email=$ACME_EMAIL|domain=$DOMAIN|redir-list=$REDIR_LIST|mta-sts-txt=$mtasts|ts-authkey=$TS_AUTHKEY|postgres-experiments-scram=$hash|webdav-htpasswd=$htpasswd"

# Direct WireGuard path for Tailscale; without it, traffic falls back to DERP
# relays over outbound 443. Created once, shared by reprovisioned instances.
gcloud compute firewall-rules describe allow-tailscale-wireguard >/dev/null 2>&1 || \
    gcloud compute firewall-rules create allow-tailscale-wireguard \
        --direction=INGRESS --allow=udp:41641

# Daily image rebuild picks up package updates. Cloud Scheduler guarantees the
# trigger with retries. GitHub's own cron is best-effort, so it is not used.
gcloud scheduler jobs describe bootc-build --location="${ZONE%-*}" >/dev/null 2>&1 || \
    gcloud scheduler jobs create http bootc-build \
        --location="${ZONE%-*}" \
        --schedule='23 9 * * *' \
        --uri=https://api.github.com/repos/varuniyer/bootc-setup/actions/workflows/build-and-deploy.yml/dispatches \
        --http-method=post \
        --headers="Authorization=Bearer $GH_WORKFLOW_TOKEN,Accept=application/vnd.github+json" \
        --message-body='{"ref":"main"}' \
        --max-retry-attempts=5 \
        --attempt-deadline=120s
