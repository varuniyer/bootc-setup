# bootc-setup

This repository defines a bootc-based Fedora image for a single-node personal web stack: a static website (Hugo), WebDAV storage, MTA-STS policy hosting, and a PostgreSQL 17 instance for experiments. The image carries no site-specific values. The served domain, credentials, and Tailscale auth key all come from GCE instance metadata at provision time, so the same image works for any deployment.

Caddy listens on port 443 for the public site. Postgres and WebDAV are reachable only over Tailscale. On first boot, tailscaled joins the tailnet as `tag:server` and `tailscale serve` forwards tailnet TCP 5432 to local Postgres and terminates HTTPS for a loopback WebDAV listener. The filesystem layout follows the conventions described in the [Fedora bootc documentation](https://docs.fedoraproject.org/en-US/bootc/).

## How it works

- `Containerfile` builds on `quay.io/fedora/fedora-bootc:latest`. A separate stage uses `xcaddy` to compile Caddy with the `webdav` plugin, and another copies the static `tailscale`/`tailscaled` binaries from the official image. `setup.sh` installs `caddy` (for the user, group, and systemd unit) and `postgresql17-server`, swaps in the custom caddy binary, removes `openssh-server`, then enables the services.
- On a recurring schedule, GitLab CI builds the image with `podman`, pushes it to the container registry, and rebuilds a GCP disk image as a recovery seed.
- The running VM updates itself from the registry via the `bootc-fetch-apply-updates` timer. The GCP image is only for new VMs and disaster recovery.
- `/etc` is transient (`prepare-root.conf`), so all runtime configuration is re-rendered from `/usr/etc` templates and instance metadata on every boot. Persistent state lives under `/var`.

## Access

Postgres and WebDAV are tailnet-only. On first boot, `post-startup-tailscale.sh` logs the node in with an auth key from instance metadata and configures `tailscale serve`: tailnet TCP 5432 forwards to Postgres on localhost (connections arrive from 127.0.0.1, matching `pg_hba.conf`), and HTTPS on the node's `ts.net` name proxies to Caddy's loopback WebDAV listener with a Tailscale-managed certificate.

The tailnet must have **MagicDNS** and **HTTPS certificates** enabled (admin console, DNS page). Without them the WebDAV endpoint fails its TLS handshake with no server-side log. The first request after enabling may stall for a few seconds while tailscaled obtains the Let's Encrypt certificate.

Access control lives in the tailnet policy file, managed in the admin console. Clients may reach `tag:server` on TCP 443 and 5432 only, and the server can initiate nothing on the tailnet. WireGuard provides transport encryption and per-device authentication. The SCRAM and basic-auth passwords remain as defense in depth against other tailnet devices.

Postgres:

```bash
psql 'postgresql://experiments:<PASSWORD>@<host>.<tailnet>.ts.net:5432/experiments'
```

WebDAV, e.g. with rclone (`type = webdav`, `vendor = other`, plus the `WEBDAV_*` credentials from `provision.env`):

```bash
rclone ls dav:   # url = https://<host>.<tailnet>.ts.net/
```

## Configuration

Deployment values live in `provision.env`, which is gitignored because it holds plaintext secrets. Copy `provision.env.example` to `provision.env` and fill it in before running `provision.sh`:

- `DOMAIN`: the primary domain Caddy serves. It replaces `${DOMAIN}` throughout the Caddyfile, so the image itself carries no domain.
- `ACME_EMAIL`: the email Caddy registers with the ACME CA.
- `REDIR_LIST`: comma-separated Caddy site addresses that permanently redirect to `https://${DOMAIN}`.
- `MTA_STS_URL`: URL `provision.sh` fetches the MTA-STS policy body from. The fetched text is stored in metadata and served at `/.well-known/mta-sts.txt`.
- `TS_AUTHKEY`: Tailscale OAuth client secret (scoped to `auth_keys` write on `tag:server` only), used directly as a non-expiring auth key on first boot.
- `POSTGRES_PASSWORD`, `WEBDAV_USERNAME`, `WEBDAV_PASSWORD`: credentials that `provision.sh` hashes locally so only the hashes reach instance metadata.

`provision.sh` pushes these into instance metadata, creates the instance, and idempotently creates the `allow-tailscale-wireguard` firewall rule (UDP 41641) for direct WireGuard paths. Without the rule, Tailscale still works through DERP relays over outbound 443. `post-startup-root.sh` renders the metadata values into `/etc/caddy/Caddyfile` on each boot.

## Reprovisioning

To rebuild the instance from scratch: delete the VM, run `provision.sh` again, and **delete the old machine in the Tailscale admin console**. A recreated VM registers as a new node (e.g. `<host>-1`) while the dead node keeps the MagicDNS name, which leaves clients connecting to a black-holed address. Removing the stale machine lets the name reattach to the live node. The OAuth client secret in `provision.env` does not expire, so no other credentials need refreshing.

## Hardening

The host has no SSH server and no GCP service account. nftables loads a static default-drop ruleset for both input and output. Inbound traffic is limited to the web ports, the Tailscale tunnel interface, and WireGuard UDP. Outbound traffic is limited to DNS, NTP, HTTP(S), and Tailscale's WireGuard and STUN ports. The GCE metadata service is reachable by root only. tailscaled runs with `--netfilter-mode=off` (persisted in its state) so it never modifies the ruleset.

Every service, including the oneshot boot-setup units, runs under a systemd sandbox: `ProtectSystem=strict` with explicit writable paths, private devices/tmp/IPC, kernel and hostname protections, `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service` on the native architecture, restricted address families, and an empty or minimal capability bounding set. Deviations are deliberate and per-service. Caddy keeps `CAP_NET_BIND_SERVICE` for port 443. tailscaled runs as a `DynamicUser` with only `CAP_NET_ADMIN`, a `DeviceAllow` for `/dev/net/tun`, and `AF_NETLINK` for interface and route programming. The root-side boot unit keeps just enough capability to perform its read-only first-boot probe of the postgres data directory. Secrets are staged through a root/postgres-bridging `creds` group and a runtime directory that is deleted after first boot, and they flow through stdin and files rather than argv or the environment.

## Layout

- `Containerfile`: image definition. Multi-stage build includes an `xcaddy` step that produces a custom caddy binary with the `webdav` plugin and a stage that copies the Tailscale binaries. Final stage runs `setup.sh` once.
- `setup.sh`: all build-time mutations. Installs packages, swaps in the custom caddy binary, creates `/var` state directories with correct ownership and permissions, creates the `creds` group bridging root and postgres, and enables services.
- `post-startup-root.{sh,service}`: root-side boot setup. Renders `/etc/caddy/Caddyfile` from the `/usr/etc` template using instance metadata, and on first boot stages the Postgres SCRAM verifier at `/run/post-startup-postgresql/hash`.
- `tailscaled.service`: full unit for the copied-in tailscaled binary (the RPM that would normally ship it is not installed).
- `post-startup-tailscale.{sh,service}`: first-boot tailnet login using the metadata auth key, plus the two `tailscale serve` entries. Completion is markered in the unit's own `StateDirectory`, and the serve config persists in tailscaled state.
- `post-startup-postgresql.{sh,service}`: postgres-side boot setup. Runs `initdb` on first boot, refreshes Postgres configs from `/usr/share/postgres/` each boot, and invokes `bootstrap.sh` when a staged SCRAM verifier is present.
- `bootstrap.sh`: applies the first-boot SQL from `/usr/share/postgres/bootstrap.sql`, setting the `experiments` role password from the staged SCRAM verifier.
- `Caddyfile`, `prepare-root.conf`, `bootc.json`, `nftables.conf`: standalone configs copied to their target paths. `Caddyfile` is a template whose metadata-backed variables (`acme-email`, `domain`, `redir-list`, `mta-sts-txt`, `webdav-username`, `webdav-password-hash`) are rendered by `post-startup-root.sh`.
- `hash-pg-password/`: containerized SCRAM-SHA-256 hasher used by `provision.sh` so the Postgres password is hashed without a local Postgres install.
- `provision.sh`: reads all deployment values from `provision.env`, hashes the Postgres and WebDAV passwords locally, and creates the GCP instance with the hashes and the remaining values in instance metadata.
- `provision.env.example`: template for the gitignored `provision.env` that `provision.sh` reads.
- `postgresql/`: `postgresql.conf`, `pg_hba.conf` (copied into `/var/lib/pgsql/data/` each boot by `post-startup-postgresql.sh`), and `bootstrap.sql` (role+db creation SQL run once on first boot by `bootstrap.sh`).
- `website/`: static site sources (Hugo).
- `build-and-deploy.sh` and `.gitlab-ci.yml`: CI for image push and GCP image build.
