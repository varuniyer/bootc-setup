#!/usr/bin/env bash
set -euo pipefail

IMAGE="$(jq -r '.transports.docker | keys[0]' containers/policy.json):latest"
source "$PWD/gcp.env"

# The runner ships no gcloud. Extract outside the build context to keep it lean.
curl -sSf --retry 3 --retry-all-errors https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-arm.tar.gz | tar -xz -C /opt
PATH="/opt/google-cloud-sdk/bin:$PATH"

podman login "${IMAGE%%/*}" -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD"
podman build --layers=false -f Containerfile -t "$IMAGE" .
# Signatures go to the registry as sigstore attachments, where the VM looks for them.
mkdir -p /etc/containers/registries.d && cp containers/bootc-setup.yaml /etc/containers/registries.d/
podman push --sign-by-sigstore-private-key <(printf '%s' "$SIGSTORE_PRIVATE_KEY") --sign-passphrase-file <(printf '%s' "$SIGSTORE_PASSPHRASE") "$IMAGE"

mkdir -p output
podman run --rm --privileged --pull=newer -v "$PWD/output:/output" -v "$(podman info --format '{{.Store.GraphRoot}}'):/var/lib/containers/storage" \
  quay.io/centos-bootc/bootc-image-builder:latest --type raw --use-librepo=True --rootfs ext4 "$IMAGE"

ARCHIVE="gs://$SEED_BUCKET/$SEED_IMAGE.tar.gz"
tar --format=oldgnu -Sczf - -C output/image disk.raw | gcloud storage cp - "$ARCHIVE"
gcloud compute images delete "$SEED_IMAGE" --quiet || true
gcloud compute images create "$SEED_IMAGE" --source-uri="$ARCHIVE" --guest-os-features=UEFI_COMPATIBLE,GVNIC
gcloud storage rm "$ARCHIVE"
