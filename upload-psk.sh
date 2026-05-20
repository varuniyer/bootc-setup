#!/usr/bin/env bash
set -euo pipefail

# One-time: store the stunnel PSK in GCP instance metadata.
# On next boot, post-startup.sh fetches it once and writes /var/lib/stunnel/psk.txt.
#
# Usage: ./provision.sh <instance> <zone> <psk>

INSTANCE=${1:?usage: $0 <instance> <zone> <psk>}
ZONE=${2:?usage: $0 <instance> <zone> <psk>}
PSK=${3:?usage: $0 <instance> <zone> <psk>}

gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" \
    --metadata "stunnel-psk=varuniyer:${PSK}"
