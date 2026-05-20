#!/usr/bin/env bash
set -euo pipefail

# Generates a stunnel PSK, writes it to ~/.config/stunnel/varuniyer.psk,
# and uploads it to GCP instance metadata.
# On next boot, post-startup.sh fetches it once and writes /var/lib/stunnel/psk.txt.
#
# Usage: ./create-and-upload-psk.sh <instance> <zone>

INSTANCE=${1:?usage: $0 <instance> <zone>}
ZONE=${2:?usage: $0 <instance> <zone>}

PSK=$(openssl rand -hex 32)
PSK_FILE="$HOME/.config/stunnel/varuniyer.psk"

mkdir -p "$(dirname "$PSK_FILE")"
printf 'varuniyer:%s\n' "$PSK" > "$PSK_FILE"
chmod 0600 "$PSK_FILE"

gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" \
    --metadata "stunnel-psk=varuniyer:${PSK}"
