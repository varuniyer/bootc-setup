#!/usr/bin/env bash
set -euo pipefail

SIZE="25G"
IMAGE="ghcr.io/varuniyer/bootc-setup:latest"
OUT="$(pwd)/output"
RAW="$OUT/disk.raw"
TARBALL="$OUT/disk.tar.gz"
GCS_BUCKET="bootc"
IMAGE_NAME="bootc"

mkdir -p "$OUT"
sudo rm -rf /run/libpod /tmp/storage-run-*
rm -f "$RAW" "$TARBALL"
truncate -s "$SIZE" "$RAW"

sudo podman pull $IMAGE
sudo podman run --rm --privileged \
    --pid=host --ipc=host \
    --security-opt label=type:unconfined_t \
    --tmpfs /run \
    -v /dev:/dev \
    -v /var/lib/containers:/var/lib/containers \
    -v "$OUT:/output" \
    --entrypoint /bin/bash \
    "$IMAGE" \
    -c "
        rm -rf /run/libpod /tmp/storage-run-* /var/tmp/storage-run-* /var/tmp/libpod-* 2>/dev/null
        exec bootc install to-disk \
            --target-imgref '$IMAGE' \
            --generic-image \
            --filesystem ext4 \
            --karg rw --karg console=tty0 --karg console=ttyS0 \
            --via-loopback \
            /output/disk.raw
    "

tar --format=oldgnu -Sczf "$TARBALL" -C "$OUT" disk.raw

gsutil cp "$TARBALL" "gs://$GCS_BUCKET/$IMAGE_NAME.tar.gz"
gcloud compute images delete "$IMAGE_NAME" --quiet || true
gcloud compute images create "$IMAGE_NAME" \
    --source-uri="gs://$GCS_BUCKET/$IMAGE_NAME.tar.gz" \
    --guest-os-features=UEFI_COMPATIBLE
gsutil rm "gs://$GCS_BUCKET/$IMAGE_NAME.tar.gz"
