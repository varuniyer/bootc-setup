#!/usr/bin/env bash
set -euo pipefail

# Generates a stunnel PSK and hashes a caddy WebDAV password, writes them
# locally, and uploads both to GCP instance metadata.
# post-startup.sh fetches them on boot.
#
# Usage: ./create-and-upload-auth.sh <instance> <zone>

INSTANCE=${1:?usage: $0 <instance> <zone>}
ZONE=${2:?usage: $0 <instance> <zone>}

PSK=$(openssl rand -hex 32)
PSK_FILE="$HOME/.config/stunnel/varuniyer.psk"
mkdir -p "$(dirname "$PSK_FILE")"
printf 'varuniyer:%s\n' "$PSK" > "$PSK_FILE"
chmod 0600 "$PSK_FILE"

read -rsp 'WebDAV password: ' CADDY_PASSWORD
printf '\n'
CADDY_HASH=$(caddy hash-password --plaintext "$CADDY_PASSWORD")

gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" \
    --metadata "stunnel-psk=varuniyer:${PSK}"
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" \
    --metadata "caddy-hashed-password=${CADDY_HASH}"
