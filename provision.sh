#!/usr/bin/env bash
set -euo pipefail

# Generates auth secrets and creates the GCP instance with them in metadata
# at creation time. post-startup-postgresql.sh and bootstrap.sh fetch them on first boot.
#
# Usage: ./provision.sh

ZONE=us-central1-a
WORK=$(mktemp -d "$HOME/tmp/provision.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

read_password() {
    local line
    printf '%s' "$1" >&2
    read -rs line
    printf '\n' >&2
    printf '%s\n' "$line" > "$2"
    unset line
}

# Postgres password as SCRAM-SHA-256 verifier, hashed inside an ephemeral postgres:17-alpine container.
read -rp 'Postgres allowlist IPs (space-separated): ' POSTGRES_IPS
printf '%s' "$POSTGRES_IPS" > "$WORK/pg-ips"
read_password 'Postgres password: ' "$WORK/pg-pw"
podman run --rm -i --user postgres \
    -v "$PWD/hash-pg-password:/hash-pg-password:Z,ro" \
    docker.io/library/postgres:17-alpine /bin/sh /hash-pg-password/run.sh < "$WORK/pg-pw" > "$WORK/pg-hash"

read_password 'WebDAV username: ' "$WORK/dav-user"
read_password 'WebDAV password: ' "$WORK/dav-pw"
caddy hash-password --algorithm argon2id < "$WORK/dav-pw" > "$WORK/dav-hash"


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
    --metadata-from-file "postgres-ip-allowlist=$WORK/pg-ips,postgres-experiments-scram=$WORK/pg-hash,webdav-username=$WORK/dav-user,webdav-password-hash=$WORK/dav-hash"
