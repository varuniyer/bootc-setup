#!/usr/bin/env bash
set -euo pipefail

IMAGE="$(jq -r '.transports.docker | keys[0]' containers/policy.json):latest"
source "$PWD/build.env"

# The runner ships no gcloud. Extract outside the build context to keep it lean.
curl -sSf --retry 3 --retry-all-errors https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-arm.tar.gz | tar -xz -C /opt
PATH="/opt/google-cloud-sdk/bin:$PATH"

printf '%s' "$GITHUB_TOKEN" | podman login --password-stdin -u "$GITHUB_ACTOR" "${IMAGE%%/*}"
podman build --layers=false --build-arg WEBSITE_REPO="$WEBSITE_REPO" -f Containerfile -t "$IMAGE" .
# Signatures go to the registry as sigstore attachments, where the VM looks for them.
mkdir -p /etc/containers/registries.d && cp containers/bootc-setup.yaml /etc/containers/registries.d/
podman push --sign-by-sigstore-private-key <(printf '%s' "$SIGSTORE_PRIVATE_KEY") --sign-passphrase-file <(printf '%s' "$SIGSTORE_PASSPHRASE") "$IMAGE"

mkdir -p output
GRAPH_ROOT=$(podman info --format '{{.Store.GraphRoot}}')
podman run --rm --privileged --pull=newer -v "$PWD/output:/output" -v "$GRAPH_ROOT:/var/lib/containers/storage" \
  quay.io/centos-bootc/bootc-image-builder:latest --type raw --use-librepo=True --rootfs ext4 "$IMAGE"

ARCHIVE="gs://$SEED_BUCKET/$SEED_IMAGE.tar.gz"
tar --format=oldgnu -Sczf - -C output/image disk.raw | gcloud storage cp - "$ARCHIVE"
gcloud compute images delete "$SEED_IMAGE" --quiet || true
gcloud compute images create "$SEED_IMAGE" \
    --source-uri="$ARCHIVE" \
    --guest-os-features=UEFI_COMPATIBLE,GVNIC
gcloud storage rm "$ARCHIVE"
