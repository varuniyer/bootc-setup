#!/usr/bin/env bash
set -euo pipefail

SIZE="${1:-25G}"
IMAGE="ghcr.io/varuniyer/bootc-setup:latest"
OUT="$(pwd)/output"
RAW="$OUT/disk.raw"

mkdir -p "$OUT"
sudo rm -rf /run/libpod /tmp/storage-run-*
rm -f "$RAW"
truncate -s "$SIZE" "$RAW"

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
