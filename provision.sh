#!/usr/bin/env bash
set -euo pipefail

# Generates auth secrets and creates the GCP instance with them in metadata
# at creation time. post-startup.sh and bootstrap.sh fetch them on first boot.
#
# Usage: ./provision.sh

ZONE=us-central1-a

# Postgres password as SCRAM-SHA-256 verifier, hashed inside an ephemeral postgres:17-alpine container.
read -rsp 'Postgres password: ' PG_PASSWORD
printf '\n'
PG_HASH=$(printf '%s' "$PG_PASSWORD" | podman run --rm -i --user postgres \
    docker.io/library/postgres:17-alpine /bin/sh -c "$(cat hash-pg-password.sh)")

read -rsp 'WebDAV password: ' CADDY_PASSWORD
printf '\n'
CADDY_HASH=$(echo "$CADDY_PASSWORD" | caddy hash-password --algorithm argon2id)

read -rp 'Postgres allowlist IPs (space-separated): ' POSTGRES_IPS

gcloud compute instances create bootc \
    --zone="$ZONE" \
    --machine-type=e2-small \
    --image=bootc \
    --boot-disk-size=200GB \
    --boot-disk-type=pd-standard \
    --address=bootc-ip \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --no-service-account \
    --no-scopes \
    --metadata "^@^postgres-experiments-scram=${PG_HASH}@caddy-hashed-password=${CADDY_HASH}@postgres-ip-allowlist=${POSTGRES_IPS}"
