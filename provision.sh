#!/usr/bin/env bash
set -euo pipefail

# Creates SM secrets and the GCP instance. post-startup.sh fetches secrets
# on boot via the instance's service account.
#
# Usage: ./provision.sh

ZONE=us-central1-a
SA=486263569732-compute@developer.gserviceaccount.com

upsert_secret() {
    local name="$1" value="$2"
    if gcloud secrets describe "$name" &>/dev/null; then
        printf '%s' "$value" | gcloud secrets versions add "$name" --data-file=-
    else
        printf '%s' "$value" | gcloud secrets create "$name" \
            --data-file=- \
            --replication-policy=automatic
        gcloud secrets add-iam-policy-binding "$name" \
            --member="serviceAccount:${SA}" \
            --role="roles/secretmanager.secretAccessor" \
            --quiet
    fi
}

PSK=$(openssl rand -hex 32)
PSK_FILE="$HOME/.config/stunnel/postgres.psk"
mkdir -p "$(dirname "$PSK_FILE")"
printf 'postgres:%s\n' "$PSK" > "$PSK_FILE"
chmod 0600 "$PSK_FILE"

read -rsp 'WebDAV password: ' CADDY_PASSWORD
printf '\n'
CADDY_HASH=$(caddy hash-password --plaintext "$CADDY_PASSWORD")

upsert_secret stunnel-psk "postgres:${PSK}"
upsert_secret caddy-hashed-password "$CADDY_HASH"

gcloud compute instances create bootc \
    --zone="$ZONE" \
    --machine-type=e2-small \
    --image=bootc \
    --boot-disk-size=25GB \
    --boot-disk-type=pd-standard \
    --address=bootc-ip \
    --scopes=cloud-platform \
    --shielded-vtpm \
    --shielded-integrity-monitoring
