#!/usr/bin/env bash
set -euo pipefail

# Generates auth secrets and creates the GCP instance with them in metadata
# at creation time. post-startup.sh and bootstrap.sh fetch them on first boot.
#
# Usage: ./provision.sh

ZONE=us-central1-a

WORK=$(mktemp -d "$HOME/tmp/provision.XXXXXX")
trap 'rm -rf "$WORK"; stty echo 2>/dev/null || true' EXIT

# Postgres password as SCRAM-SHA-256 verifier, hashed inside an ephemeral postgres:17-alpine container.
printf 'Postgres password: ' >&2
stty -echo
head -n 1 | tr -d '\n' > "$WORK/pg-pw"
stty echo
printf '\n' >&2
podman run --rm -i --user postgres \
    -v "$PWD/hash-pg-password:/hash-pg-password:Z,ro" \
    docker.io/library/postgres:17-alpine /bin/sh /hash-pg-password/run.sh < "$WORK/pg-pw" > "$WORK/pg-hash"
rm -f "$WORK/pg-pw"

printf 'WebDAV password: ' >&2
stty -echo
head -n 1 | tr -d '\n' > "$WORK/caddy-pw"
stty echo
printf '\n' >&2
caddy hash-password --algorithm argon2id < "$WORK/caddy-pw" > "$WORK/caddy-hash"
rm -f "$WORK/caddy-pw"

read -rp 'Postgres allowlist IPs (space-separated): ' POSTGRES_IPS
printf '%s' "$POSTGRES_IPS" > "$WORK/pg-ips"

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
    --metadata-from-file "postgres-experiments-scram=$WORK/pg-hash,caddy-hashed-password=$WORK/caddy-hash,postgres-ip-allowlist=$WORK/pg-ips"
