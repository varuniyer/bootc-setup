# bootc-setup

Immutable bootc-based Fedora image for a single-node personal web stack: a public Hugo site plus tailnet-only WebDAV and PostgreSQL, with stateless configuration rendered from GCE instance metadata on every boot.

The image carries no deployment-specific values. The served domain, credentials, and Tailscale OAuth client secret all flow from GCE instance metadata at provision time, so the same image deploys to any GCP project on an Arm machine type. The image does name this repository's `ghcr.io` package, which it pulls and verifies updates from. Caddy serves the public site and the MTA-STS policy at `mta-sts.<DOMAIN>` on port 443, while PostgreSQL and WebDAV are strictly private, accessible only over your Tailscale tailnet.

Filesystem layout follows the conventions described in the [Fedora bootc documentation](https://docs.fedoraproject.org/en-US/bootc/).

## Architecture

- **Stateless Configuration**: `/etc` is configured as transient via `prepare-root.conf`, so every boot starts it fresh from the image's `/usr/etc`. Boot scripts then write the files derived from instance metadata. Persistent state lives exclusively under `/var`.
- **Base Image**: `Containerfile` builds upon `quay.io/fedora/fedora-bootc:latest`. The final stage copies `tailscale`, `tailscaled`, `caddy`, and `rclone` from their official images, and a dedicated stage builds PostgreSQL from source against the same base. No service is installed through dnf. `setup.sh` removes SSH and unused services, creates users, installs Caddy's SELinux module, fixes permissions, rebuilds the initramfs, and enables services.
- **Continuous Integration**: A GitHub Actions workflow builds the arm64 image with Podman, signs it, pushes it to `ghcr.io`, and rebuilds the GCE seed image. A Cloud Scheduler job dispatches the workflow daily so package updates ship even without commits. Pushes that change only `README.md` or `AGENTS.md` skip the build, and a newer run cancels one in progress.
- **Automatic Updates**: The running VM pulls updates from `ghcr.io` through the `bootc-fetch-apply-updates` systemd timer and reboots to apply each one. Since CI builds daily, expect a reboot whenever a new build lands. The seed image is only used for initial VM creation and disaster recovery.
- **Signed Images**: CI signs each pushed image with a sigstore key. `containers/policy.json` makes the VM accept an update only when its signature verifies against the public key from instance metadata.

## Deployment & Configuration

`provision.sh` holds the non-secret configuration and prompts for secrets. It pushes the configuration, the password hashes, and the Tailscale OAuth client secret into GCE instance metadata, stores the GitHub PAT in a Cloud Scheduler job, and stores the signing key in GitHub Actions.

### 1. Prepare the Project
Install Podman, the gcloud CLI, and the [GitHub CLI](https://cli.github.com/). Run `gh auth login` as an account that can manage this repository's Actions secrets and variables, and `gcloud auth login` as a project owner. Select the project with `gcloud config set project`, then enable the APIs that the script and CI use:
```bash
gcloud services enable compute.googleapis.com cloudscheduler.googleapis.com iam.googleapis.com iamcredentials.googleapis.com storage.googleapis.com
```
CI authenticates through the IAM Credentials API. `provision.sh` never calls that API itself, so gcloud never offers to enable it, and without it the first build fails while the script waits for its seed image.

In the Tailscale admin console, enable HTTPS certificates for the tailnet and create an OAuth client with `auth_keys` write scope on `tag:server`. In the policy file, give `tag:server` a `tagOwners` entry and grant clients access to `tag:server` on TCP 5432 and 8080 only.

Then edit the settings at the top of `provision.sh`:
- `ZONE`, `MACHINE_TYPE`, `DISK_SIZE`, `DISK_TYPE`: GCP zone, instance type, and boot disk shape passed to `gcloud compute instances create`. The image is arm64, so `MACHINE_TYPE` must be an Arm type, and `postgresql.conf` is sized for `c4a-standard-1`.
- `DOMAIN`: Primary domain Caddy serves (fills `{$DOMAIN}` in the Caddyfile).
- `ACME_EMAIL`: Email for ACME CA registration.
- `REDIR_LIST`: Comma-separated addresses that permanently redirect to the same path on `https://<DOMAIN>`.
- `MTA_STS_URL`: URL that `provision.sh` fetches the MTA-STS policy body from, once. To pick up a later change to that policy, update the `mta-sts-txt` metadata value and reset the VM.
- `WEBDAV_USERNAME`: WebDAV login name.

The script prompts for these secrets without echoing them:
- Tailscale OAuth client secret. It never expires, so the same value works on every reprovisioning.
- Fine-grained GitHub PAT with Actions read/write on this repository only. The `bootc-build` Cloud Scheduler job stores it in its request headers to dispatch the daily build, and the script asks for it only while that job is missing. When the PAT expires, the daily builds stop until you replace it with the snippet below.
- PostgreSQL `experiments` password and WebDAV password. `provision.sh` hashes these locally so only the hashes reach instance metadata.

Each secret and password hash lives in an unexported shell variable and reaches other processes through stdin or a `/dev/fd` path, so it stays out of argv, the environment, shell history, and local disk.

To replace an expired PAT the same way, run this in an interactive shell, changing `us-central1` if `ZONE` is in another region:
```bash
read -rsp 'GitHub PAT: ' GH_WORKFLOW_TOKEN && echo
gcloud scheduler jobs update http bootc-build --location=us-central1 --flags-file=<(printf -- '--update-headers: "Authorization=Bearer %s"\n' "$GH_WORKFLOW_TOKEN") && unset GH_WORKFLOW_TOKEN
```

### 2. Provision the Instance
```bash
./provision.sh
```
This script pushes configuration into instance metadata and creates the VM. When they are missing, it also creates the `bootc-ip` static address, the `allow-web` firewall rule (TCP 80 and 443), the `allow-tailscale-wireguard` firewall rule (UDP 41641) for direct WireGuard paths, and the `bootc-build` Cloud Scheduler job that dispatches the daily image build. It also gives CI access to GCP without a stored key. GitHub Actions runs on `main` act as the `bootc-ci` service account through Workload Identity Federation, and that account can only write the `bootc` bucket and GCE images. On its first run, the script also creates the image signing key pair. The private key and its passphrase become Actions secrets, the public key becomes the `SIGSTORE_PUBLIC_KEY` Actions variable, and a signed build starts. On a fresh project, the script waits for that build's seed image before creating the VM. Later runs reuse the key. To rotate it, delete that variable before reprovisioning. On boot, `post-startup-root.sh` writes the metadata values to `/run/caddy` for Caddy's native `{$VAR}` substitution, renders `/etc/rclone/webdav.htpasswd`, and writes the signing public key to `/etc/pki/containers/sigstore.pub`.

Point A records for `<DOMAIN>`, `mta-sts.<DOMAIN>`, and every `REDIR_LIST` name at the `bootc-ip` address. The address survives VM deletion, so the records stay valid across reprovisioning. MTA-STS also needs the `_mta-sts.<DOMAIN>` TXT record that your mail provider specifies.

A project's `default` network starts with `default-allow-ssh` and `default-allow-rdp` rules. Nothing on this VM listens on those ports. Delete them unless other VMs in the project still need SSH or RDP:
```bash
gcloud compute firewall-rules delete default-allow-ssh default-allow-rdp
```

### 3. Remove First-Boot Values
After provisioning, verify that you can connect to PostgreSQL over the tailnet. Then remove the values the VM reads only on its first boot from instance metadata:
```bash
gcloud compute instances remove-metadata bootc --keys=ts-authkey,postgres-experiments-scram
```
Removing `ts-authkey` matters most, because the Tailscale OAuth client secret never expires. Removing these values does not affect reboots, but wait for the PostgreSQL check above, since it confirms that the first boot succeeded. The remaining metadata values are re-read on every boot and must stay.

## Access

PostgreSQL and WebDAV are reachable exclusively over the tailnet.

On first boot, `post-startup-tailscale.sh` logs the node in. On every boot, it resets the `tailscale serve` config to match the script. Tailnet TCP 5432 forwards to local PostgreSQL, and tailnet HTTPS 8080 proxies to a loopback rclone WebDAV server. Your Tailscale policy file from step 1 decides which clients reach those ports.

**PostgreSQL**:
```bash
psql 'postgresql://experiments:<PASSWORD>@bootc.<tailnet>.ts.net:5432/experiments'
```

**WebDAV**:
WebDAV is served over HTTPS under the node's MagicDNS name. `tailscaled` terminates TLS, obtains the Let's Encrypt certificate on the first request, renews it automatically, and caches it under `/var/lib/tailscale`, so the certificate survives reboots and image updates. Configure `rclone` (`type = webdav`, `vendor = rclone`) using `WEBDAV_USERNAME` and the WebDAV password, then access it via:
```bash
rclone ls webdav:   # url = https://bootc.<tailnet>.ts.net:8080
```

## Reprovisioning

Deleting the VM also deletes its boot disk, and with it everything under `/var`: the PostgreSQL data, WebDAV files, Caddy certificates, and Tailscale state. Copy off anything you need first. To rebuild the instance from scratch:
1. **Delete the old machine in the Tailscale admin console**, so the new VM can register under the `bootc` MagicDNS name.
2. Delete the existing VM in GCP.
3. Run `./provision.sh`.
4. Repeat step 3 of the deployment to remove the first-boot values.

## Hardening

The host minimizes attack surface via strict networking and systemd sandboxing rules:

- **Network**: No SSH server, client, or host keys in the image, no login prompt on any console, and no avahi (mDNS) or NFS services. `nftables` loads a static default-drop ruleset. Inbound traffic is restricted to web ports and WireGuard UDP. Outbound is limited to DNS, NTP, HTTP(S), and Tailscale ports. Only root can reach the GCE metadata service. `tailscaled` runs in userspace networking mode, so no tunnel interface exists and it never alters host rules.
- **Systemd Sandboxing**: Every service this repository ships, including the oneshot boot units, runs under a strict systemd sandbox: `ProtectSystem=strict`, private devices/tmp/IPC, `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`, restricted address families, and minimal capability bounding sets.
- **Least Privilege**: Deviations from the sandbox are deliberate. Caddy retains `CAP_NET_BIND_SERVICE` and runs confined as SELinux `httpd_t`. A local module (`caddy_local.cil`) lets it connect to `http_port_t` ports for ACME and OCSP, and nftables narrows its outbound traffic to ports 80 and 443. `tailscaled` and the WebDAV server run completely unprivileged as `DynamicUser` services with empty capability sets.
- **Secret Handling**: Secrets are staged through a `creds` group bridging root and postgres. The WebDAV `htpasswd` is rendered root-only and delivered via systemd `LoadCredential`.

## Repository Layout

### Build & Provisioning
- `Containerfile`: Multi-stage build definition.
- `setup.sh`: Build-time mutations (SSH, mDNS, NFS, and console login removal, users, Caddy's SELinux module, permissions, the initramfs rebuild, service enablement).
- `provision.sh`: Hashes passwords locally, sets up the daily build, CI's GCP access, and the signing key, and creates the address, firewall rules, and GCP instance.
- `build-and-deploy.sh` / `.github/workflows/build-and-deploy.yml`: CI pipeline that builds, signs, and pushes the image and rebuilds the seed image.

### Boot Setup Scripts & Services
- `post-startup-root.{sh,service}`: Root-side boot setup. Renders runtime configuration files from metadata.
- `fetch_metadata.sh`: Helper the boot scripts use to read GCE instance metadata attributes.
- `rclone-webdav.service`: Sandboxed WebDAV server running `rclone serve`.

### Service Folders
- `caddy/`: `Caddyfile` (static, with `{$VAR}` placeholders Caddy fills from `/run/caddy/env`), the sandboxed `caddy.service` for the statically copied binary, `caddy_local.cil` (SELinux allow rule for ACME), and `tmpfiles.conf`.
- `postgresql/`: Server configs (`postgresql.conf`, `pg_hba.conf`), `build.sh` (the source build that runs in its own Containerfile stage), the sandboxed `postgresql.service`, boot setup (`post-startup-postgresql.{sh,service}`, `bootstrap.sh`, `bootstrap.sql`), and `tmpfiles.conf`.
- `tailscale/`: `tailscaled.service` for the statically copied binary and tailnet login and serve setup (`post-startup-tailscale.{sh,service}`).

### Configuration
- `prepare-root.conf`, `bootc.json`, `nftables.conf`, `fstab`, `journald.conf`: Standalone configuration files.
- `containers/`: `policy.json`, which requires a valid signature on this repository's registry image and accepts local `containers-storage` images so the CI seed build can install the unsigned image it just built, `bootc-setup.yaml`, which stores and reads those signatures as sigstore attachments in the registry, and `sigpolicy.toml`, which makes `bootc install` record the image as `ostree-image-signed`.
- `hash-pg-password/`: Containerized SCRAM-SHA-256 hasher to generate secure PostgreSQL password hashes locally without a host installation.
- `website/`: Static site source files (Hugo), including the `404.html` page Caddy serves for unknown paths.
