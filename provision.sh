#!/usr/bin/env bash
set -euo pipefail

# Prompts for secrets, hashes the passwords locally, sets up the daily build, CI's GCP
# access, and the signing key, and creates the GCP instance with the results in
# metadata. Usage: ./provision.sh

ZONE=us-central1-b
MACHINE_TYPE=c4a-standard-1
DISK_SIZE=150GB
DISK_TYPE=hyperdisk-balanced
DOMAIN=varuniyer.net
ACME_EMAIL=acme@varuniyer.net
REDIR_LIST="varuniyer.info, varuniyer.me, www.varuniyer.net, www.varuniyer.info, www.varuniyer.me"
MTA_STS_URL=https://mta-sts.forwardemail.net/.well-known/mta-sts.txt
WEBDAV_USERNAME=dav

# Secrets stay unexported shell variables and reach other processes only through
# stdin or /dev/fd paths, never argv, the environment, or disk.
read_secret() { read -rsp "$1: " "$2"; echo >&2; }

# Daily image rebuild picks up package updates. Cloud Scheduler guarantees the
# trigger with retries. GitHub's own cron is best-effort, so it is not used.
gcloud scheduler jobs describe bootc-build --location="${ZONE%-*}" >/dev/null 2>&1 || {
    read_secret 'GitHub PAT with Actions read/write on this repo' GH_WORKFLOW_TOKEN
    gcloud scheduler jobs create http bootc-build \
        --location="${ZONE%-*}" \
        --schedule='0 0 * * *' \
        --uri=https://api.github.com/repos/varuniyer/bootc-setup/actions/workflows/build-and-deploy.yml/dispatches \
        --http-method=post \
        --flags-file=<(printf -- '--headers: "Authorization=Bearer %s,Accept=application/vnd.github+json"\n' "$GH_WORKFLOW_TOKEN") \
        --message-body='{"ref":"main"}' \
        --max-retry-attempts=5 \
        --attempt-deadline=120s
}

read_secret 'Tailscale OAuth client secret' TS_AUTHKEY
read_secret 'PostgreSQL experiments password' POSTGRES_PASSWORD
read_secret "WebDAV password for $WEBDAV_USERNAME" WEBDAV_PASSWORD

# The hashers strip the trailing newline, so the printf newline is not part of
# the hashed secret. With no network, the images have nowhere to send it.
hash=$(printf '%s\n' "$POSTGRES_PASSWORD" | podman run --rm -i --network=none --user postgres \
    -v "$PWD/hash-pg-password:/hash-pg-password:Z,ro" \
    docker.io/library/postgres:17-alpine /bin/sh /hash-pg-password/run.sh)
htpasswd=$(printf '%s' "$WEBDAV_PASSWORD" | podman run --rm -i --network=none \
    docker.io/library/httpd:alpine htpasswd -niB "$WEBDAV_USERNAME")

# CI reaches GCP through Workload Identity Federation, so no Google key exists. Only
# main-branch runs of this repo can act as bootc-ci, which writes the seed bucket and image.
project=$(gcloud config get-value project)
pool=projects/$(gcloud projects describe "$project" --format='value(projectNumber)')/locations/global/workloadIdentityPools/github
ci=bootc-ci@$project.iam.gserviceaccount.com
gcloud iam workload-identity-pools describe github --location=global >/dev/null 2>&1 || \
    gcloud iam workload-identity-pools create github --location=global
gcloud iam workload-identity-pools providers describe bootc-setup --location=global --workload-identity-pool=github >/dev/null 2>&1 || \
    gcloud iam workload-identity-pools providers create-oidc bootc-setup \
        --location=global --workload-identity-pool=github \
        --issuer-uri=https://token.actions.githubusercontent.com \
        --attribute-mapping=google.subject=assertion.sub \
        --attribute-condition="assertion.repository=='varuniyer/bootc-setup'"
gcloud iam service-accounts describe "$ci" >/dev/null 2>&1 || gcloud iam service-accounts create bootc-ci
gcloud iam roles describe bootcImages --project="$project" >/dev/null 2>&1 || \
    gcloud iam roles create bootcImages --project="$project" \
        --permissions=compute.images.create,compute.images.delete,compute.images.get,compute.globalOperations.get
gcloud storage buckets describe gs://bootc >/dev/null 2>&1 || \
    gcloud storage buckets create gs://bootc --location="${ZONE%-*}" --uniform-bucket-level-access
gcloud storage buckets add-iam-policy-binding gs://bootc --member="serviceAccount:$ci" --role=roles/storage.objectAdmin >/dev/null
gcloud projects add-iam-policy-binding "$project" --member="serviceAccount:$ci" --role="projects/$project/roles/bootcImages" --condition=None >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$ci" --role=roles/iam.workloadIdentityUser \
    --member="principal://iam.googleapis.com/$pool/subject/repo:varuniyer/bootc-setup:ref:refs/heads/main" >/dev/null
printf '%s' "$pool/providers/bootc-setup" | gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER
printf '%s' "$ci" | gh variable set GCP_SERVICE_ACCOUNT

# Image signing key pair, created once and reused on reprovisioning. The public key is
# an Actions variable so it can be read back.
vars=$(gh variable list --json name --jq '.[].name')
if ! grep -qx SIGSTORE_PUBLIC_KEY <<<"$vars"; then
    pass=$(head -c 32 /dev/urandom | base64)
    keys=$(printf '%s\n' "$pass" | podman run --rm -i --tmpfs /tmp --entrypoint sh quay.io/skopeo/stable:latest \
        -c 'skopeo generate-sigstore-key --output-prefix /tmp/k --passphrase-file /dev/stdin >&2 && cat /tmp/k.pub /tmp/k.private')
    printf '%s\n' "$keys" | sed '1,/END PUBLIC KEY/d' | gh secret set SIGSTORE_PRIVATE_KEY
    printf '%s' "$pass" | gh secret set SIGSTORE_PASSPHRASE
    printf '%s\n' "$keys" | sed '/END PUBLIC KEY/q' | gh variable set SIGSTORE_PUBLIC_KEY
fi
sigpub=$(gh variable get SIGSTORE_PUBLIC_KEY)

# A new key needs a signed build, and a fresh project needs its first seed image.
grep -qx SIGSTORE_PUBLIC_KEY <<<"$vars" && gcloud compute images describe bootc >/dev/null 2>&1 || gh workflow run build-and-deploy.yml
until gcloud compute images describe bootc >/dev/null 2>&1; do sleep 60; done

# MTA-STS policy body fetched once and baked into metadata.
mtasts=$(curl -sSf "$MTA_STS_URL")

# The static address outlives the VM, so DNS keeps pointing at reprovisioned instances.
gcloud compute addresses describe bootc-ip --region="${ZONE%-*}" >/dev/null 2>&1 || \
    gcloud compute addresses create bootc-ip --region="${ZONE%-*}"

gcloud compute instances create bootc \
    --zone="$ZONE" --machine-type="$MACHINE_TYPE" --image=bootc \
    --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" --address=bootc-ip \
    --shielded-secure-boot --shielded-vtpm --no-service-account --no-scopes \
    --metadata "^|^acme-email=$ACME_EMAIL|domain=$DOMAIN|redir-list=$REDIR_LIST|mta-sts-txt=$mtasts|sigstore-public-key=$sigpub" \
    --metadata-from-file=ts-authkey=<(printf '%s' "$TS_AUTHKEY"),postgres-experiments-scram=<(printf '%s' "$hash"),webdav-htpasswd=<(printf '%s' "$htpasswd")

gcloud compute firewall-rules describe allow-web >/dev/null 2>&1 || \
    gcloud compute firewall-rules create allow-web \
        --direction=INGRESS --allow=tcp:80,tcp:443

# Direct WireGuard path for Tailscale. Without it, traffic falls back to DERP
# relays over outbound 443. Created once, shared by reprovisioned instances.
gcloud compute firewall-rules describe allow-tailscale-wireguard >/dev/null 2>&1 || \
    gcloud compute firewall-rules create allow-tailscale-wireguard \
        --direction=INGRESS --allow=udp:41641
