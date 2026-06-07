# bootc-setup

bootc-based Fedora image for varuniyer.net. Runs the website, WebDAV, and a Postgres 17 instance for experiments. Caddy fronts everything on port 443, terminating TLS and routing by SNI: static site, webdav handler, and a layer4 forward to local postgres for `db.varuniyer.net`.

## How it works

- `Containerfile` builds on `quay.io/fedora/fedora-bootc:latest`. A separate stage uses `xcaddy` to compile Caddy with the `layer4` and `webdav` plugins. `setup.sh` installs `caddy` (for the user, group, and systemd unit) and `postgresql17-server`, swaps in the custom caddy binary, removes `openssh-server`, then enables the services.
- On every push to `main` and on a recurring schedule, GitLab CI builds the image with `podman`, pushes it to `registry.gitlab.com/varuniyer/bootc-setup:latest`, and rebuilds a GCP disk image as a recovery seed.
- The running VM updates itself from the GitLab registry via the `bootc-fetch-apply-updates` timer. The GCP image is only for new VMs and disaster recovery.

## Filesystem

- `/usr`: immutable. The container image's root content, swapped atomically by the `bootc-fetch-apply-updates` timer. `/bin`, `/sbin`, `/lib`, `/lib64` are symlinks into `/usr`.
- `/etc`: transient tmpfs, repopulated from `/usr/etc` each boot. Runtime edits are lost on reboot. Bake persistent config into `/usr/etc` at image build.
- `/var`: mutable and persistent. Survives auto-updates and reboots. Service state (`/var/lib/webdav`, `/var/lib/pgsql/data`, `/var/log/caddy`) lives here. `/home` and `/root` are symlinks into `/var`.
- `/boot`, `/boot/efi`: managed by `bootupd`, updated as part of the `bootc-fetch-apply-updates` cycle.
- `/run`, `/tmp`: tmpfs, cleared each boot.
- `/sysroot`: read-only mount of the underlying ostree storage that backs bootc deployments. Not browsed directly.

`/etc` and `/sysroot` behavior is configured in `/usr/lib/ostree/prepare-root.conf` (ostree is bootc's storage layer on Fedora today).

## Access

Postgres is exposed via Caddy's `layer4` listener on `db.varuniyer.net:443`. Caddy terminates TLS using the same publicly trusted ACME cert that fronts the website, then forwards plain protocol bytes to postgres on localhost. Only source IPs in the `postgres-ip-allowlist` instance metadata reach the postgres route, the rest are dropped at the layer4 matcher. Authorized clients connect with:

```
psql 'postgresql://experiments:<PASSWORD>@db.varuniyer.net:443/experiments?sslmode=verify-full&sslnegotiation=direct&sslrootcert=system'
```

`sslnegotiation=direct` requires libpq 17 on the client.

## Layout

- `Containerfile`: image definition. Multi-stage build includes an `xcaddy` step that produces a custom caddy binary with `layer4` + `webdav` plugins. Final stage runs `setup.sh` once.
- `setup.sh`: all build-time mutations (packages, custom caddy binary install, service enables).
- `post-startup.{sh,service}`: boot-time, idempotent. Creates `/var` state dirs with correct ownership, runs `postgresql-setup --initdb` on first boot, refreshes Postgres configs each boot, delegates first-boot SQL to `bootstrap.sh`.
- `bootstrap.sh`: first-boot postgres bootstrap. Runs `postgresql/bootstrap.sql` and applies the SCRAM verifier from instance metadata as the `experiments` role's password.
- `Caddyfile`, `prepare-root.conf`, `bootc.json`: standalone configs, each COPY'd to their target paths.
- `provision.sh`: prompts for postgres and WebDAV passwords plus the postgres IP allowlist, hashes the passwords locally (postgres via an ephemeral local postgres, webdav via `caddy hash-password`), then creates the GCP instance with the hashes and the allowlist in instance metadata. `post-startup.sh` fetches them on first boot: postgres hash is applied by `bootstrap.sh`, caddy hash and IP allowlist are substituted into the Caddyfile template.
- `postgresql/`: `postgresql.conf`, `pg_hba.conf` (copied into `/var/lib/pgsql/data/` each boot by `post-startup.sh`), and `bootstrap.sql` (role+db creation SQL run once on first boot by `bootstrap.sh`).
- `website/`: static site sources (Hugo).
- `build-and-deploy.sh` and `.gitlab-ci.yml`: CI for image push and GCP image build.
