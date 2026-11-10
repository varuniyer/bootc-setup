# bootc-setup

Immutable bootc-based Fedora image for a single-node personal web stack: a public Hugo site plus tailnet-only WebDAV and PostgreSQL, with stateless configuration rendered from GCE instance metadata on every boot.

The image carries no site-specific values. The served domain, credentials, and Tailscale auth key all flow from GCE instance metadata at provision time, meaning the exact same image can be deployed anywhere. Caddy serves the public site and the MTA-STS policy at `mta-sts.<DOMAIN>` on port 443, while PostgreSQL and WebDAV are strictly private, accessible only over your Tailscale tailnet.

Filesystem layout follows the conventions described in the [Fedora bootc documentation](https://docs.fedoraproject.org/en-US/bootc/).

## Architecture

- **Stateless Configuration**: `/etc` is configured as transient via `prepare-root.conf`, so every boot starts it fresh from the image's `/usr/etc`. Boot scripts then write the files derived from instance metadata. Persistent state lives exclusively under `/var`.
- **Base Image**: `Containerfile` builds upon `quay.io/fedora/fedora-bootc:latest`. The final stage copies `tailscale`, `tailscaled`, `caddy`, and `rclone` from their official images, and a dedicated stage builds PostgreSQL from source against the same base. No service is installed through dnf. `setup.sh` removes SSH and handles users, permissions, and service enablement.
- **Continuous Integration**: A GitHub Actions workflow builds the image with Podman, pushes it to `ghcr.io`, and rebuilds a GCP disk image to serve as a recovery seed. A Cloud Scheduler job dispatches the workflow daily so package updates ship even without commits.
- **Automatic Updates**: The running VM updates itself directly from the container registry via the `bootc-fetch-apply-updates` systemd timer. The GCP image is only used for disaster recovery or initial VM creation.
- **Signed Images**: CI signs each pushed image with a sigstore key. `containers/policy.json` makes the VM accept an update only when its signature verifies against the public key from instance metadata.

## Deployment & Configuration

`provision.sh` holds the non-secret configuration, prompts for secrets, and pushes both into GCE instance metadata.

### 1. Prepare Credentials
Install Podman, the gcloud CLI, and the [GitHub CLI](https://cli.github.com/). Run `gh auth login` as an account that can manage this repository's Actions secrets and variables, and `gcloud auth login` as a project owner. Then edit the settings at the top of `provision.sh`:
- `ZONE`, `MACHINE_TYPE`, `DISK_SIZE`, `DISK_TYPE`: GCP zone, instance type, and boot disk shape passed to `gcloud compute instances create`.
- `DOMAIN`: Primary domain Caddy serves (fills `{$DOMAIN}` in the Caddyfile).
- `ACME_EMAIL`: Email for ACME CA registration.
- `REDIR_LIST`: Comma-separated addresses that permanently redirect to `https://${DOMAIN}`.
- `MTA_STS_URL`: URL where `provision.sh` fetches the MTA-STS policy body.
- `WEBDAV_USERNAME`: WebDAV login name.

The script prompts for these secrets without echoing them:
- Tailscale OAuth client secret (scoped to `auth_keys` write on `tag:server`).
- Fine-grained GitHub PAT with Actions read/write on this repository only. Cloud Scheduler uses it to dispatch the daily build workflow. The script asks for it only while the `bootc-build` job is missing.
- PostgreSQL `experiments` password and WebDAV password. `provision.sh` hashes these locally so only the hashes reach instance metadata.

Each secret lives in an unexported shell variable and reaches other processes through stdin or a `/dev/fd` path, so it stays out of argv, the environment, shell history, and disk.

### 2. Provision the Instance
```bash
./provision.sh
```
This script pushes configuration into instance metadata, creates the VM, and idempotently creates the `bootc-ip` static address, the `allow-web` firewall rule (TCP 80 and 443), the `allow-tailscale-wireguard` firewall rule (UDP 41641) for direct WireGuard paths, and the `bootc-build` Cloud Scheduler job that dispatches the daily image build. It also gives CI access to GCP without a stored key. GitHub Actions runs on `main` act as the `bootc-ci` service account through Workload Identity Federation, and that account can only write the `bootc` bucket and GCE images. On its first run, the script also creates the image signing key pair. The private key and its passphrase become Actions secrets, the public key becomes the `SIGSTORE_PUBLIC_KEY` Actions variable, and a signed build starts. On a fresh project, the script waits for that build's seed image before creating the VM. Later runs reuse the key. To rotate it, delete that variable before reprovisioning. On boot, `post-startup-root.sh` writes the metadata values to `/run/caddy` for Caddy's native `{$VAR}` substitution, renders `/etc/rclone/webdav.htpasswd`, and writes the signing public key to `/etc/pki/containers/sigstore.pub`.

Point DNS records for `DOMAIN`, `mta-sts.<DOMAIN>`, and every `REDIR_LIST` name at the `bootc-ip` address. The address survives VM deletion, so the records stay valid across reprovisioning.

### 3. Clean Up Single-Use Secrets
After provisioning, verify that you can connect to PostgreSQL over the tailnet. Once verified, remove the single-use secrets from instance metadata:
```bash
gcloud compute instances remove-metadata bootc --keys=ts-authkey,postgres-experiments-scram
```
These secrets are only consumed on the very first boot. Removing them does not affect reboots, but do not remove them until the PostgreSQL connection check above confirms that the first boot succeeded. The remaining metadata values are re-read on every boot and must stay.

## Access

PostgreSQL and WebDAV are reachable exclusively over the tailnet.

On first boot, `post-startup-tailscale.sh` logs the node in. On every boot, it resets the `tailscale serve` config to match the script. Tailnet TCP 5432 forwards to local PostgreSQL, and tailnet HTTPS 8080 proxies to a loopback rclone WebDAV server. Access control is managed in your Tailscale admin console policy file: clients may reach `tag:server` on TCP 5432 and 8080 only.

**PostgreSQL**:
```bash
psql 'postgresql://experiments:<PASSWORD>@bootc.<tailnet>.ts.net:5432/experiments'
```

**WebDAV**:
WebDAV is served over HTTPS under the node's MagicDNS name, which requires HTTPS certificates to be enabled for the tailnet. `tailscaled` terminates TLS, obtains the Let's Encrypt certificate on the first request, renews it automatically, and caches it under `/var/lib/tailscale`, so the certificate survives reboots and image updates. Configure `rclone` (`type = webdav`, `vendor = rclone`) using `WEBDAV_USERNAME` and the WebDAV password, then access it via:
```bash
rclone ls webdav:   # url = https://bootc.<tailnet>.ts.net:8080
```

## Reprovisioning

To rebuild the instance from scratch:
1. Delete the existing VM in GCP.
2. Run `./provision.sh`.
3. **Delete the old machine in the Tailscale admin console.** Because a recreated VM registers as a new node, the dead node will hold onto the MagicDNS name until removed.
4. Repeat the metadata cleanup step for single-use secrets.

*Note: The Tailscale OAuth client secret does not expire, so the same value works on every reprovisioning.*

## Hardening

The host minimizes attack surface via strict networking and systemd sandboxing rules:

- **Network**: No SSH server, client, or host keys in the image, no login prompt on any console, and no avahi (mDNS) or NFS services. `nftables` loads a static default-drop ruleset. Inbound traffic is restricted to web ports and WireGuard UDP. Outbound is limited to DNS, NTP, HTTP(S), and Tailscale ports. Only root can reach the GCE metadata service. `tailscaled` runs in userspace networking mode, so no tunnel interface exists and it never alters host rules.
- **Systemd Sandboxing**: Every service, including oneshot boot units, runs under a strict systemd sandbox: `ProtectSystem=strict`, private devices/tmp/IPC, `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`, restricted address families, and minimal capability bounding sets.
- **Least Privilege**: Deviations from the sandbox are deliberate. Caddy retains `CAP_NET_BIND_SERVICE` and runs confined as SELinux `httpd_t`, with a local module (`caddy_local.cil`) allowing only outbound HTTP(S) for ACME. `tailscaled` and the WebDAV server run completely unprivileged as `DynamicUser` services with empty capability sets.
- **Secret Handling**: Secrets are staged through a `creds` group bridging root and postgres. The WebDAV `htpasswd` is rendered root-only and delivered via systemd `LoadCredential`.

## Repository Layout

### Build & Provisioning
- `Containerfile`: Multi-stage build definition.
- `setup.sh`: Build-time mutations (SSH, mDNS, NFS, and console login removal, users, permissions, service enablement).
- `provision.sh`: Hashes passwords locally, sets up CI's GCP access and the signing key, and creates the GCP instance.
- `build-and-deploy.sh` / `.github/workflows/build-and-deploy.yml`: CI pipeline for building and pushing the image.

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
- `website/`: Static site source files (Hugo).
