# bootc-setup

Immutable bootc-based Fedora image for a single-node personal web stack: a public static site plus tailnet-only WebDAV and PostgreSQL, with stateless configuration rendered from GCE instance metadata on every boot.

Apart from the site it serves and this repository's `ghcr.io` registry image, which it pulls and verifies updates from, the image carries no deployment-specific values. `provision.sh` puts the served domain, password hashes, and Tailscale OAuth client secret into GCE instance metadata, and the VM reads them at boot, so the same image deploys to any GCP project on an Arm machine type. Caddy serves the public site and the MTA-STS policy at `mta-sts.<DOMAIN>` on port 443, while PostgreSQL and WebDAV are reachable only over your Tailscale tailnet.

Filesystem layout follows the conventions described in the [Fedora bootc documentation](https://docs.fedoraproject.org/en-US/bootc/).

## Architecture

- **Stateless Configuration**: `/etc` is configured as transient via `prepare-root.conf`, so every boot starts it fresh from the image's `/usr/etc`. Boot scripts then write the files derived from instance metadata. Persistent state lives exclusively under `/var`.
- **Base Image**: `Containerfile` builds upon `quay.io/fedora/fedora-bootc:latest`. The final stage copies `tailscale`, `tailscaled`, `caddy`, and `rclone` from their official images, and a dedicated stage builds PostgreSQL from source. Another stage fetches the built site and CV from the `static` branch of the [website repo](https://github.com/varuniyer/website).
- **Continuous Integration**: A GitHub Actions workflow builds the arm64 image with Podman, signs it, pushes it to `ghcr.io`, and rebuilds the GCE seed image. A Cloud Scheduler job dispatches the workflow daily so package updates ship even without commits, and the website repo dispatches it after each site build. Pushes that change only `README.md` or `AGENTS.md` skip the build, and a newer run cancels one in progress.
- **Automatic Updates**: The running VM pulls updates from `ghcr.io` through the `bootc-fetch-apply-updates` systemd timer and reboots to apply each one. The seed image is only used for initial VM creation and disaster recovery.
- **Signed Images**: CI signs each pushed image with the signing key. `containers/policy.json` makes the VM accept an update only when its signature verifies against the public key from instance metadata.

## Deployment & Configuration

`provision.sh` holds the non-secret configuration and prompts for secrets. It pushes the configuration, the password hashes, and the Tailscale OAuth client secret into GCE instance metadata, stores the GitHub PAT in a Cloud Scheduler job, and stores the signing key in GitHub Actions.

### 1. Prepare the Project
Install Podman, the gcloud CLI, and the [GitHub CLI](https://cli.github.com/). Run `gh auth login` as an account that can manage Actions secrets and variables in this repository and the website repo, and `gcloud auth login` as a project owner. Select the project with `gcloud config set project`, then enable the APIs that the script and CI use:
```bash
gcloud services enable compute.googleapis.com cloudscheduler.googleapis.com iam.googleapis.com iamcredentials.googleapis.com storage.googleapis.com
```
CI authenticates through the IAM Credentials API, which only CI calls, so gcloud's enable prompt never covers it. The first build fails until it is enabled.

In the Tailscale admin console, enable HTTPS certificates for the tailnet and create an OAuth client with `auth_keys` write scope on `tag:server`. In the policy file, give `tag:server` a `tagOwners` entry and grant clients access to `tag:server` on TCP 5432 and 8080 only.

Then edit the settings at the top of `provision.sh`:
- `ZONE`, `MACHINE_TYPE`, `DISK_SIZE`, `DISK_TYPE`: GCP zone, machine type, and the size and type of the boot disk, passed to `gcloud compute instances create`. The image is arm64, so `MACHINE_TYPE` must be an Arm type, and `postgresql.conf` is sized for `c4a-standard-1`.
- `DOMAIN`: Primary domain Caddy serves (fills `{$DOMAIN}` in the Caddyfile).
- `ACME_EMAIL`: Email address for the ACME account.
- `REDIR_LIST`: Comma-separated domains that permanently redirect to the same path on `https://<DOMAIN>`.
- `MTA_STS_URL`: URL that `provision.sh` fetches the MTA-STS policy body from, once. To pick up a later change to that policy, update the `mta-sts-txt` metadata value and reset the VM.
- `WEBDAV_USERNAME`: WebDAV login name.
- `REPO`, `BRANCH`: GitHub repository and branch that the daily build dispatches. Workflow runs from that branch act as the CI service account.
- `WEBSITE_REPO`: GitHub repository whose site build dispatches this repository's workflow.

The script prompts for these secrets without echoing them:
- Tailscale OAuth client secret. It never expires, so the same value works on every reprovisioning.
- Fine-grained GitHub PAT with Actions read/write on this repository only. The `bootc-build` Cloud Scheduler job stores it to dispatch the daily build, and `WEBSITE_REPO` stores it as the `GH_WORKFLOW_TOKEN` Actions secret to dispatch the same workflow after each site build. The script asks for it only while that job is missing. When the PAT expires, both dispatches stop until you replace it with the snippet below.
- PostgreSQL `experiments` password and WebDAV password. `provision.sh` hashes these locally so only the hashes reach instance metadata.

`provision.sh` keeps each secret and password hash out of argv, the environment, shell history, and local disk.

To replace an expired PAT the same way, run this in an interactive shell, with `--location` set to the `REGION` that `provision.sh` derives from `ZONE`:
```bash
read -rsp 'GitHub PAT: ' GH_WORKFLOW_TOKEN && echo
CLOUDSDK_CORE_DISABLE_FILE_LOGGING=1 gcloud scheduler jobs update http bootc-build --location=us-central1 --flags-file=<(printf -- '--update-headers: "Authorization=Bearer %s"\n' "$GH_WORKFLOW_TOKEN")
printf '%s' "$GH_WORKFLOW_TOKEN" | gh secret set GH_WORKFLOW_TOKEN --repo varuniyer/website && unset GH_WORKFLOW_TOKEN
```

### 2. Provision the VM
```bash
./provision.sh
```
This script pushes configuration into instance metadata and creates the VM. When they are missing, it also creates the `bootc-ip` static address, the `allow-web` firewall rule (TCP 80 and 443), the `allow-tailscale-wireguard` firewall rule (UDP 41641) for direct WireGuard paths, and the `bootc-build` Cloud Scheduler job that dispatches the daily image build. It also gives CI access to GCP without a stored key. GitHub Actions runs on `main` act as the `bootc-ci` service account through Workload Identity Federation, and that account can only write the `bootc-seed-upload` bucket and GCE images. On its first run, the script also creates the signing key pair. The private key and its passphrase become Actions secrets, the public key becomes the `SIGSTORE_PUBLIC_KEY` Actions variable, and a signed build starts. On a fresh project, the script waits for that build's seed image before creating the VM. Later runs reuse the key. To rotate it, delete that variable before reprovisioning.

Point A records for `<DOMAIN>`, `mta-sts.<DOMAIN>`, and every `REDIR_LIST` domain at the `bootc-ip` address. The address survives VM deletion, so the records stay valid across reprovisioning. MTA-STS also needs the `_mta-sts.<DOMAIN>` TXT record that your mail provider specifies.

A project's `default` network starts with `default-allow-ssh` and `default-allow-rdp` rules. Nothing on this VM listens on those ports. Delete them unless other VMs in the project still need SSH or RDP:
```bash
gcloud compute firewall-rules delete default-allow-ssh default-allow-rdp
```

### 3. Remove First-Boot Values
After provisioning, verify that you can connect to PostgreSQL over the tailnet. Then remove the values the VM reads only on its first boot from instance metadata:
```bash
gcloud compute instances remove-metadata bootc --keys=ts-oauth-secret,postgresql-experiments-hash
```
Removing `ts-oauth-secret` matters most, because that secret works indefinitely. The PostgreSQL check confirms that the first boot used both values, and later boots read neither. Until the Tailscale login and the PostgreSQL bootstrap succeed, every boot retries them from these values. If the check fails, keep both values and reset the VM with `gcloud compute instances reset bootc`. The remaining metadata values are re-read on every boot and must stay.

## Access

On first boot, `boot-tailscale.sh` logs the node in. Its `tailscale serve` config forwards tailnet TCP 5432 to local PostgreSQL and proxies tailnet HTTPS 8080 to a loopback rclone WebDAV server. Your Tailscale policy file from step 1 decides which clients reach those ports.

**PostgreSQL**:
```bash
psql 'postgresql://experiments:<PASSWORD>@bootc.<tailnet>.ts.net:5432/experiments'
```

**WebDAV**: WebDAV is served over HTTPS under the node's MagicDNS name. `tailscaled` terminates TLS. It obtains the Let's Encrypt certificate on the first request and renews it automatically, and the certificate survives reboots and image updates. Configure `rclone` (`type = webdav`, `vendor = rclone`) using `WEBDAV_USERNAME` and the WebDAV password, then access it via:
```bash
rclone ls webdav:   # url = https://bootc.<tailnet>.ts.net:8080
```

## Reprovisioning

Deleting the VM also deletes its boot disk, and with it everything under `/var`: the PostgreSQL data, WebDAV files, Caddy certificates, and Tailscale state. Copy off anything you need first. To reprovision the VM:
1. **Delete the old node from the Machines page of the Tailscale admin console**, so the new VM can register under the `bootc` MagicDNS name.
2. Delete the existing VM in GCP.
3. Run `./provision.sh`.
4. Repeat step 3 of the deployment to remove the first-boot values.

## Hardening

The VM minimizes attack surface via strict networking rules and systemd sandboxing:

- **Network**: No SSH server, client, or host keys in the image, no login prompt on any console, and no avahi (mDNS) or NFS services. `nftables` loads a static default-drop ruleset. Inbound traffic is restricted to web ports, WireGuard UDP, DHCP replies, and rate-limited ICMP echo requests. Outbound is limited to DHCP, DNS, NTP, HTTP(S), Tailscale ports, and ICMP. IPv6 is dropped on every path, loopback included. Only root can reach the GCE metadata service. `tailscaled` runs in userspace networking mode, so no tunnel interface exists and it never alters the VM's nftables rules.
- **Systemd Sandboxing**: Every service this repository ships, including the oneshot boot units, runs under the strict systemd sandbox in `hardening.conf`. Each unit file adds only its own differences, such as its capability bounding set and writable paths.
- **Least Privilege**: Caddy retains `CAP_NET_BIND_SERVICE` and runs confined as SELinux `httpd_t`. A local module (`caddy_local.cil`) lets it connect to `http_port_t` ports for ACME and OCSP. `tailscaled` and the WebDAV server run unprivileged as `DynamicUser` services with empty capability sets.
- **Secret Handling**: Root stages the PostgreSQL password hash in a `creds`-group file, which `bootstrap.sh` reads as postgres. The WebDAV `htpasswd` is rendered root-only and delivered via systemd `LoadCredential`.

## Repository Layout

### Build & Provisioning
- `Containerfile`: Multi-stage build definition.
- `setup.sh`: Applies every build-time mutation. It removes SSH, mDNS, NFS, and the console login, creates users, installs Caddy's SELinux module, fixes permissions, rebuilds the initramfs, links the shared sandbox into each unit, enables services, and runs `bootc container lint`, so a lint error fails the build.
- `provision.sh`: Provisioning script (see Deployment & Configuration).
- `gcp.env`: Seed image and bucket names that `provision.sh` and `build-and-publish.sh` both source.
- `build-and-publish.sh` / `.github/workflows/build-and-publish.yml`: CI pipeline that builds, signs, and pushes the image and rebuilds the seed image.

### Boot Scripts & Services
- `boot-root.{sh,service}`: Runs as root and renders runtime configuration files from metadata.
- `fetch_metadata.sh`: Helper the boot scripts use to read GCE instance metadata values.
- `rclone-webdav.service`: Sandboxed WebDAV server running `rclone serve`.

### Service Folders
- `caddy/`: `Caddyfile` (static, with `{$VAR}` placeholders filled from instance metadata), the sandboxed `caddy.service` for the statically copied binary, `caddy_local.cil` (SELinux module for Caddy's outbound HTTP), and `caddy-dirs.conf`.
- `postgresql/`: Server configs (`postgresql.conf`, `pg_hba.conf`), `build.sh` (the source build that runs in its own Containerfile stage), the sandboxed `postgresql.service`, boot scripts (`boot-postgresql.{sh,service}`, `bootstrap.sh`, `bootstrap.sql`), and `postgresql-dirs.conf`.
- `tailscale/`: `tailscaled.service` for the statically copied binary and tailnet login and serve config (`boot-tailscale.{sh,service}`).

### Configuration
- `prepare-root.conf`, `nftables.conf`, `fstab`, `journald.conf`: Standalone configuration files.
- `hardening.conf`: Shared systemd sandbox that every shipped unit links into its `.service.d/`.
- `tmpfiles.d/root.conf`: Masks systemd's `root.conf` tmpfiles entry.
- `containers/`: Signature policy for image updates. `policy.json` requires a valid signature on this repository's registry image and accepts local `containers-storage` images, so the CI seed build can install the unsigned image it just built. `bootc-setup.yaml` stores and reads those signatures as sigstore attachments in the registry. `sigpolicy.toml` makes `bootc install` enforce the signature policy.
- `hash-postgresql-password/`: Containerized SCRAM-SHA-256 hasher to generate PostgreSQL password hashes without a local PostgreSQL installation.
