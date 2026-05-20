#!/usr/bin/env bash
set -euo pipefail

# Creates the GCP instance, generates auth secrets, and uploads them to metadata.
# post-startup.sh fetches them on first boot.
#
# Usage: ./provision.sh

ZONE=us-central1-a

INSTANCE_ID=$(gcloud compute instances create bootc \
    --zone="$ZONE" \
    --machine-type=e2-small \
    --image=bootc \
    --boot-disk-size=40GB \
    --boot-disk-type=pd-standard \
    --address=bootc-ip \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --format="value(id)")

PSK=$(openssl rand -hex 32)
PSK_FILE="$HOME/.config/stunnel/postgres.psk"
mkdir -p "$(dirname "$PSK_FILE")"
printf 'varuniyer:%s\n' "$PSK" > "$PSK_FILE"
chmod 0600 "$PSK_FILE"

read -rsp 'WebDAV password: ' CADDY_PASSWORD
printf '\n'
CADDY_HASH=$(caddy hash-password --plaintext "$CADDY_PASSWORD")

gcloud compute instances add-metadata "$INSTANCE_ID" --zone="$ZONE" \
    --metadata "stunnel-psk=varuniyer:${PSK}"
gcloud compute instances add-metadata "$INSTANCE_ID" --zone="$ZONE" \
    --metadata "caddy-hashed-password=${CADDY_HASH}"
