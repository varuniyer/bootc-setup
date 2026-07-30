#!/usr/bin/env bash
set -euo pipefail

IMAGE="$CI_REGISTRY_IMAGE:latest"
GCS_BUCKET="bootc"
GCE_IMAGE="bootc"

# The runner ships no gcloud. Extract outside the build context to keep it lean.
curl -sSf https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-arm.tar.gz | tar -xz -C /opt
PATH="/opt/google-cloud-sdk/bin:$PATH"

podman login "$CI_REGISTRY" -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD"
# Runner image 20260726 pairs podman 5.8 with a stale /usr/bin/crun (actions/runner-images#14473).
podman build --runtime "$(command -v crun)" --layers=false -f Containerfile -t "$IMAGE" .
podman push "$IMAGE"

mkdir -p output
STORAGE=$(podman info --format '{{.Store.GraphRoot}}')
podman run --runtime "$(command -v crun)" --rm --privileged --pull=newer \
  -v "$PWD/output:/output" -v "$STORAGE:/var/lib/containers/storage" \
  quay.io/centos-bootc/bootc-image-builder:latest --type raw --use-librepo=True --rootfs ext4 "$IMAGE"

tar --format=oldgnu -Sczf output/bootc.tar.gz -C output/image disk.raw

gcloud auth activate-service-account --key-file=<(printf '%s' "$GCP_SA_KEY")
gcloud storage cp output/bootc.tar.gz "gs://$GCS_BUCKET/$GCE_IMAGE.tar.gz"
gcloud compute images delete "$GCE_IMAGE" --quiet || true
gcloud compute images create "$GCE_IMAGE" --source-uri="gs://$GCS_BUCKET/$GCE_IMAGE.tar.gz" --guest-os-features=UEFI_COMPATIBLE,GVNIC
gcloud storage rm "gs://$GCS_BUCKET/$GCE_IMAGE.tar.gz"
