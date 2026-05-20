#!/usr/bin/env bash
set -euo pipefail

# Generates auth secrets and creates the GCP instance with them set in
# metadata at creation time. post-startup.sh fetches them on first boot.
#
# Usage: ./provision.sh

ZONE=us-central1-a

PSK=$(openssl rand -hex 32)
PSK_FILE="$HOME/.config/stunnel/postgres.psk"
mkdir -p "$(dirname "$PSK_FILE")"
printf 'postgres:%s\n' "$PSK" > "$PSK_FILE"
chmod 0600 "$PSK_FILE"

read -rsp 'WebDAV password: ' CADDY_PASSWORD
printf '\n'
CADDY_HASH=$(caddy hash-password --plaintext "$CADDY_PASSWORD")

gcloud compute instances create bootc \
    --zone="$ZONE" \
    --machine-type=e2-small \
    --image=bootc \
    --boot-disk-size=25GB \
    --boot-disk-type=pd-standard \
    --address=bootc-ip \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --metadata "stunnel-psk=postgres:${PSK},caddy-hashed-password=${CADDY_HASH}"
