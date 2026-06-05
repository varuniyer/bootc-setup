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
PG_HASH=$(podman run --rm -i --user postgres -e PW="$PG_PASSWORD" \
    docker.io/library/postgres:17-alpine /bin/sh < hash-pg-password.sh)

read -rsp 'WebDAV password: ' CADDY_PASSWORD
printf '\n'
CADDY_HASH=$(caddy hash-password --algorithm argon2id --plaintext "$CADDY_PASSWORD")

# Firewall rules from firewall.conf. Delete + recreate so edits to existing rules apply.
while read -r name action rule tag; do
    gcloud compute firewall-rules delete "$name" --quiet >/dev/null 2>&1 || true
    gcloud compute firewall-rules create "$name" --direction=INGRESS --action="$action" --rules="$rule" --target-tags="$tag"
done < firewall.conf

gcloud compute instances create bootc \
    --zone="$ZONE" \
    --machine-type=e2-small \
    --image=bootc \
    --boot-disk-size=25GB \
    --boot-disk-type=pd-standard \
    --address=bootc-ip \
    --tags=http-server,https-server,no-ssh \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --metadata "postgres-experiments-scram=${PG_HASH},caddy-hashed-password=${CADDY_HASH}"
