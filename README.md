# bootc-setup

Immutable bootc-based Fedora image for a single-node personal web stack: a public Hugo site plus tailnet-only WebDAV and PostgreSQL, with stateless configuration rendered from GCE instance metadata on every boot.

The image carries no site-specific values. The served domain, credentials, and Tailscale auth key all flow from GCE instance metadata at provision time, meaning the exact same image can be deployed anywhere. Caddy handles the public site on port 443, while PostgreSQL and WebDAV are strictly private, accessible only over your Tailscale tailnet.

Filesystem layout follows the conventions described in the [Fedora bootc documentation](https://docs.fedoraproject.org/en-US/bootc/).

## Architecture

- **Stateless Configuration**: `/etc` is configured as transient via `prepare-root.conf`. All runtime configurations are re-rendered from `/usr/etc` templates and instance metadata on every boot. Persistent state lives exclusively under `/var`.
- **Base Image**: `Containerfile` builds upon `quay.io/fedora/fedora-bootc:latest`. The final stage copies `tailscale`, `tailscaled`, `caddy`, `rclone`, and `envsubst` from their official images, and a dedicated stage builds PostgreSQL from source against the same base. No service is installed through dnf. `setup.sh` removes SSH and handles users, permissions, and service enablement.
- **Continuous Integration**: A GitHub Actions workflow builds the image with Podman, pushes it to `ghcr.io`, and rebuilds a GCP disk image to serve as a recovery seed. A Cloud Scheduler job dispatches the workflow daily so package updates ship even without commits.
- **Automatic Updates**: The running VM updates itself directly from the container registry via the `bootc-fetch-apply-updates` systemd timer. The GCP image is only used for disaster recovery or initial VM creation.

## Deployment & Configuration

Configuration is managed via `dotenvx` and pushed to GCE instance metadata during provisioning.

### 1. Prepare Credentials
Install [dotenvx](https://github.com/dotenvx/dotenvx#quickstart---), then copy the environment template:
```bash
cp .env.example .env
```
Fill in the values in `.env`:
- `ZONE`, `MACHINE_TYPE`, `DISK_SIZE`, `DISK_TYPE`: GCP zone, instance type, and boot disk shape passed to `gcloud compute instances create`.
- `DOMAIN`: Primary domain Caddy serves (fills `{$DOMAIN}` in the Caddyfile).
- `ACME_EMAIL`: Email for ACME CA registration.
- `REDIR_LIST`: Comma-separated addresses that permanently redirect to `https://${DOMAIN}`.
- `MTA_STS_URL`: URL where `provision.sh` fetches the MTA-STS policy body.
- `TS_AUTHKEY`: Tailscale OAuth client secret (scoped to `auth_keys` write on `tag:server`).
- `GH_WORKFLOW_TOKEN`: Fine-grained GitHub PAT with Actions read/write on this repository only. Cloud Scheduler uses it to dispatch the daily build workflow.
- `POSTGRES_PASSWORD`, `WEBDAV_USERNAME`, `WEBDAV_PASSWORD`: Plaintext credentials. `provision.sh` hashes these locally so only secure hashes reach instance metadata.

Once filled, encrypt the file:
```bash
dotenvx encrypt
```
*Note: Never commit `.env.keys`. Do not commit `.env` until it has been encrypted.*

### 2. Provision the Instance
Run the provisioning script using `dotenvx`:
```bash
dotenvx run -- ./provision.sh
```
This script pushes configuration into instance metadata, creates the VM, and idempotently creates the `allow-tailscale-wireguard` firewall rule (UDP 41641) for direct WireGuard paths and the `bootc-build` Cloud Scheduler job that dispatches the daily image build. On boot, `post-startup-root.sh` writes the metadata values to `/run/caddy` for Caddy's native `{$VAR}` substitution and renders `/etc/rclone/webdav.htpasswd`.

### 3. Clean Up Single-Use Secrets
After provisioning, verify that you can connect to PostgreSQL over the tailnet. Once verified, remove the single-use secrets from instance metadata:
```bash
gcloud compute instances remove-metadata bootc --keys=ts-authkey,postgres-experiments-scram
```
These secrets are only consumed on the very first boot. Removing them does not affect reboots, but do not remove them until the PostgreSQL connection check above confirms that the first boot succeeded. The remaining metadata values are re-read on every boot and must stay.

## Access

PostgreSQL and WebDAV are reachable exclusively over the tailnet.

On first boot, `post-startup-tailscale.sh` logs the node in and configures `tailscale serve`. Tailnet TCP 5432 forwards to local PostgreSQL, and tailnet TCP 8080 forwards to a loopback rclone WebDAV server. Access control is managed in your Tailscale admin console policy file: clients may reach `tag:server` on TCP 5432 and 8080 only.

**PostgreSQL**:
```bash
psql 'postgresql://experiments:<PASSWORD>@bootc.<tailnet>.ts.net:5432/experiments'
```

**WebDAV**:
WebDAV is served as plain HTTP because WireGuard already provides transport encryption and per-device authentication, eliminating the need for TLS on the tailnet path. Configure `rclone` (`type = webdav`, `vendor = rclone`) using the credentials from `.env`, then access it via:
```bash
rclone ls dav:   # url = http://bootc.<tailnet>.ts.net:8080
```

## Reprovisioning

To rebuild the instance from scratch:
1. Delete the existing VM in GCP.
2. Run `dotenvx run -- ./provision.sh`.
3. **Delete the old machine in the Tailscale admin console.** Because a recreated VM registers as a new node, the dead node will hold onto the MagicDNS name until removed.
4. Repeat the metadata cleanup step for single-use secrets.

*Note: The OAuth client secret in `.env` does not expire, so no credentials need refreshing prior to reprovisioning.*

## Hardening

The host minimizes attack surface via strict networking and systemd sandboxing rules:

- **Network**: No SSH server, client, or host keys in the image. `nftables` loads a static default-drop ruleset. Inbound traffic is restricted to web ports and WireGuard UDP. Outbound is limited to DNS, NTP, HTTP(S), and Tailscale ports. Only root can reach the GCE metadata service. `tailscaled` runs in userspace networking mode, so no tunnel interface exists and it never alters host rules.
- **Systemd Sandboxing**: Every service, including oneshot boot units, runs under a strict systemd sandbox: `ProtectSystem=strict`, private devices/tmp/IPC, `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`, restricted address families, and minimal capability bounding sets.
- **Least Privilege**: Deviations from the sandbox are deliberate. Caddy retains `CAP_NET_BIND_SERVICE`. `tailscaled` and the WebDAV server run completely unprivileged as `DynamicUser` services with empty capability sets.
- **Secret Handling**: Secrets are staged through a `creds` group bridging root and postgres. The WebDAV `htpasswd` is rendered root-only and delivered via systemd `LoadCredential`.

## Repository Layout

### Build & Provisioning
- `Containerfile`: Multi-stage build definition.
- `setup.sh`: Build-time mutations (SSH removal, users, permissions, service enablement).
- `provision.sh`: Hashes passwords locally and creates the GCP instance.
- `build-and-deploy.sh` / `.github/workflows/build-and-deploy.yml`: CI pipeline for building and pushing the image.
- `.env.example`: Template for environment variables.

### Boot Setup Scripts & Services
- `post-startup-root.{sh,service}`: Root-side boot setup. Renders runtime configuration files from metadata.
- `fetch_metadata.sh`: Helper the boot scripts use to read GCE instance metadata attributes.
- `rclone-webdav.service`: Sandboxed WebDAV server running `rclone serve`.

### Service Folders
- `caddy/`: `Caddyfile` (static, with `{$VAR}` placeholders Caddy fills from `/run/caddy/env`), the sandboxed `caddy.service` for the statically copied binary, and `tmpfiles.conf`.
- `postgresql/`: Server configs (`postgresql.conf`, `pg_hba.conf`), `build.sh` (the source build that runs in its own Containerfile stage), the sandboxed `postgresql.service`, boot setup (`post-startup-postgresql.{sh,service}`, `bootstrap.sh`, `bootstrap.sql`), and `tmpfiles.conf`.
- `tailscale/`: `tailscaled.service` for the statically copied binary and first-boot tailnet setup (`post-startup-tailscale.{sh,service}`).

### Configuration
- `prepare-root.conf`, `bootc.json`, `nftables.conf`, `fstab`, `journald.conf`, `99-synproxy.conf`: Standalone configuration files.
- `hash-pg-password/`: Containerized SCRAM-SHA-256 hasher to generate secure PostgreSQL password hashes locally without a host installation.
- `website/`: Static site source files (Hugo).
