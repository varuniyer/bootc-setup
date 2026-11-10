#!/usr/bin/env bash
set -euo pipefail

ZONE=us-central1-b
REGION=${ZONE%-*}
MACHINE_TYPE=c4a-standard-1
DISK_SIZE=150GB
DISK_TYPE=hyperdisk-balanced
DOMAIN=varuniyer.net
ACME_EMAIL=acme@varuniyer.net
REDIR_LIST="varuniyer.info, varuniyer.me, www.varuniyer.net, www.varuniyer.info, www.varuniyer.me"
MTA_STS_URL=https://mta-sts.forwardemail.net/.well-known/mta-sts.txt
WEBDAV_USERNAME=dav
REPO=varuniyer/bootc-setup
BRANCH=main
WEBSITE_REPO=varuniyer/website

source "$PWD/gcp.env"

# Secrets stay unexported shell variables and reach other processes only through
# stdin or /dev/fd paths, never argv, the environment, or disk.
read_secret() { read -rsp "$1: " "$2"; echo >&2; }

# The daily build picks up package updates. Cloud Scheduler retries a failed dispatch.
# The website repo's publish workflow dispatches the same build with the same PAT.
build_job=bootc-build
gcloud scheduler jobs describe "$build_job" --location="$REGION" >/dev/null 2>&1 || {
    read_secret 'GitHub PAT with Actions read/write on this repo' GH_WORKFLOW_TOKEN
    CLOUDSDK_CORE_DISABLE_FILE_LOGGING=1 gcloud scheduler jobs create http "$build_job" \
        --location="$REGION" \
        --schedule='0 0 * * *' \
        --uri="https://api.github.com/repos/$REPO/actions/workflows/build-and-publish.yml/dispatches" \
        --http-method=post \
        --flags-file=<(printf -- '--headers: "Authorization=Bearer %s,Accept=application/vnd.github+json"\n' "$GH_WORKFLOW_TOKEN") \
        --message-body="{\"ref\":\"$BRANCH\"}" \
        --max-retry-attempts=5 \
        --attempt-deadline=120s
    printf '%s' "$GH_WORKFLOW_TOKEN" | gh secret set GH_WORKFLOW_TOKEN --repo "$WEBSITE_REPO"
}

read_secret 'Tailscale OAuth client secret' TS_OAUTH_SECRET
read_secret 'PostgreSQL experiments password' POSTGRESQL_PASSWORD
read_secret "WebDAV password for $WEBDAV_USERNAME" WEBDAV_PASSWORD

# With no network, the hashers have nowhere to send the secret.
hash=$(printf '%s' "$POSTGRESQL_PASSWORD" | podman run --rm -i --log-driver=none --network=none --tmpfs /tmp --user postgres -v "$PWD/hash-postgresql-password:/hash-postgresql-password:Z,ro" \
    docker.io/library/postgres:17-alpine /bin/sh /hash-postgresql-password/run.sh)
htpasswd=$(printf '%s' "$WEBDAV_PASSWORD" | podman run --rm -i --log-driver=none --network=none \
    docker.io/library/httpd:alpine htpasswd -niB "$WEBDAV_USERNAME")

# CI reaches GCP through Workload Identity Federation with short-lived tokens. Only
# main-branch runs of this repo can act as bootc-ci, which writes the seed bucket and image.
project=$(gcloud config get-value project)
pool_id=github
provider_id=bootc-setup
role_id=bootcImages
pool=projects/$(gcloud projects describe "$project" --format='value(projectNumber)')/locations/global/workloadIdentityPools/$pool_id
service_account=bootc-ci@$project.iam.gserviceaccount.com
gcloud iam workload-identity-pools describe "$pool_id" --location=global >/dev/null 2>&1 || \
    gcloud iam workload-identity-pools create "$pool_id" --location=global
gcloud iam workload-identity-pools providers describe "$provider_id" --location=global --workload-identity-pool="$pool_id" >/dev/null 2>&1 || \
    gcloud iam workload-identity-pools providers create-oidc "$provider_id" \
        --location=global --workload-identity-pool="$pool_id" \
        --issuer-uri=https://token.actions.githubusercontent.com \
        --attribute-mapping=google.subject=assertion.sub \
        --attribute-condition="assertion.repository=='$REPO'"
gcloud iam service-accounts describe "$service_account" >/dev/null 2>&1 || gcloud iam service-accounts create "${service_account%%@*}"
gcloud iam roles describe "$role_id" --project="$project" >/dev/null 2>&1 || \
    gcloud iam roles create "$role_id" --project="$project" \
        --permissions=compute.images.create,compute.images.delete,compute.images.get,compute.globalOperations.get
gcloud storage buckets describe "gs://$SEED_BUCKET" >/dev/null 2>&1 || \
    gcloud storage buckets create "gs://$SEED_BUCKET" --location="$REGION" --uniform-bucket-level-access
gcloud storage buckets add-iam-policy-binding "gs://$SEED_BUCKET" --member="serviceAccount:$service_account" --role=roles/storage.objectAdmin >/dev/null
gcloud projects add-iam-policy-binding "$project" --member="serviceAccount:$service_account" --role="projects/$project/roles/$role_id" --condition=None >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$service_account" --role=roles/iam.workloadIdentityUser \
    --member="principal://iam.googleapis.com/$pool/subject/repo:$REPO:ref:refs/heads/$BRANCH" >/dev/null
printf '%s' "$pool/providers/$provider_id" | gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER
printf '%s' "$service_account" | gh variable set GCP_SERVICE_ACCOUNT

# Signing key pair, created once and reused on reprovisioning. The public key is
# an Actions variable so it can be read back.
key_var=$(gh variable list --json name --jq '.[].name | select(. == "SIGSTORE_PUBLIC_KEY")')
if [ -z "$key_var" ]; then
    passphrase=$(head -c 32 /dev/urandom | base64)
    keys=$(printf '%s\n' "$passphrase" | podman run --rm -i --log-driver=none --tmpfs /tmp --entrypoint sh quay.io/skopeo/stable:latest \
        -c 'skopeo generate-sigstore-key --output-prefix /tmp/k --passphrase-file /dev/stdin >&2 && cat /tmp/k.pub /tmp/k.private')
    printf '%s\n' "$keys" | sed '1,/END PUBLIC KEY/d' | gh secret set SIGSTORE_PRIVATE_KEY
    printf '%s' "$passphrase" | gh secret set SIGSTORE_PASSPHRASE
    printf '%s\n' "$keys" | sed '/END PUBLIC KEY/q' | gh variable set SIGSTORE_PUBLIC_KEY
fi
sigstore_public_key=$(gh variable get SIGSTORE_PUBLIC_KEY)

# A new key needs a signed build, and a fresh project needs its first seed image.
[ -n "$key_var" ] && gcloud compute images describe "$SEED_IMAGE" >/dev/null 2>&1 || gh workflow run build-and-publish.yml
until gcloud compute images describe "$SEED_IMAGE" >/dev/null 2>&1; do sleep 60; done

# MTA-STS policy body fetched once and baked into metadata.
mta_sts_txt=$(curl -sSf "$MTA_STS_URL")

# The static address outlives the VM, so DNS keeps pointing at reprovisioned VMs.
address=bootc-ip
gcloud compute addresses describe "$address" --region="$REGION" >/dev/null 2>&1 || \
    gcloud compute addresses create "$address" --region="$REGION"

gcloud compute instances create bootc \
    --zone="$ZONE" --machine-type="$MACHINE_TYPE" --image="$SEED_IMAGE" \
    --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" --address="$address" \
    --shielded-secure-boot --shielded-vtpm --no-service-account --no-scopes \
    --metadata "^|^acme-email=$ACME_EMAIL|domain=$DOMAIN|redir-list=$REDIR_LIST|mta-sts-txt=$mta_sts_txt|sigstore-public-key=$sigstore_public_key" \
    --metadata-from-file=ts-oauth-secret=<(printf '%s' "$TS_OAUTH_SECRET"),postgresql-experiments-hash=<(printf '%s' "$hash"),webdav-htpasswd=<(printf '%s' "$htpasswd")

web_rule=allow-web
gcloud compute firewall-rules describe "$web_rule" >/dev/null 2>&1 || \
    gcloud compute firewall-rules create "$web_rule" \
        --direction=INGRESS --allow=tcp:80,tcp:443

# Direct WireGuard path for Tailscale. Without it, traffic falls back to DERP
# relays over outbound 443. Created once, shared by reprovisioned VMs.
wireguard_rule=allow-tailscale-wireguard
gcloud compute firewall-rules describe "$wireguard_rule" >/dev/null 2>&1 || \
    gcloud compute firewall-rules create "$wireguard_rule" \
        --direction=INGRESS --allow=udp:41641
