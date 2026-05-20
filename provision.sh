#!/usr/bin/env bash
set -euo pipefail

# Creates the GCP instance, then writes secrets directly to /var over SSH
# once the VM is up. post-startup.sh reads them from /var on every boot.
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
    --shielded-integrity-monitoring

echo 'Waiting for SSH...'
until gcloud compute ssh bootc --zone="$ZONE" \
        --ssh-flag="-o StrictHostKeyChecking=no" \
        --command="exit" 2>/dev/null; do
    sleep 5
done

printf 'postgres:%s\n' "$PSK" \
    | gcloud compute ssh bootc --zone="$ZONE" \
        --ssh-flag="-o StrictHostKeyChecking=no" -- \
        "sudo bash -c 'mkdir -p /var/lib/stunnel && cat > /var/lib/stunnel/psk.txt && chmod 0600 /var/lib/stunnel/psk.txt'"

printf '%s\n' "$CADDY_HASH" \
    | gcloud compute ssh bootc --zone="$ZONE" \
        --ssh-flag="-o StrictHostKeyChecking=no" -- \
        "sudo bash -c 'mkdir -p /var/lib/caddy && cat > /var/lib/caddy/hashed-password'"
