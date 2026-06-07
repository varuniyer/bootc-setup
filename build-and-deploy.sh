#!/usr/bin/env bash
set -euo pipefail

IMAGE="ghcr.io/varuniyer/bootc-setup:latest"
GCS_BUCKET="bootc"
GCE_IMAGE="bootc"

export STORAGE_DRIVER=vfs

if ! command -v gcloud >/dev/null; then
  tee /etc/yum.repos.d/google-cloud-sdk.repo > /dev/null << EOM
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el10-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key-v10.gpg
EOM
  dnf install -y --setopt=install_weak_deps=False libxcrypt-compat google-cloud-cli
fi

podman login ghcr.io -u "$GHCR_USER" -p "$GHCR_TOKEN"
podman build -f Containerfile -t "$IMAGE" .
podman push "$IMAGE"

mkdir -p output
podman run --rm --privileged --pull=newer --security-opt label=type:unconfined_t \
  -v "$PWD/output:/output" -v "$HOME/.local/share/containers/storage:/var/lib/containers/storage" \
  quay.io/centos-bootc/bootc-image-builder:latest --in-vm --type raw --use-librepo=True --rootfs ext4 "$IMAGE"

tar --format=oldgnu -Sczf output/bootc.tar.gz -C output/image disk.raw

gcloud auth activate-service-account --key-file="$GCP_SA_KEY"
gsutil cp output/bootc.tar.gz "gs://$GCS_BUCKET/$GCE_IMAGE.tar.gz"
gcloud compute images delete "$GCE_IMAGE" --quiet || true
gcloud compute images create "$GCE_IMAGE" --source-uri="gs://$GCS_BUCKET/$GCE_IMAGE.tar.gz" --guest-os-features=UEFI_COMPATIBLE
gsutil rm "gs://$GCS_BUCKET/$GCE_IMAGE.tar.gz"
