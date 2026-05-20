# bootc-setup

bootc-based Fedora image for varuniyer.net. Runs the website, WebDAV, and a Postgres 17 instance for experiments. All three are plain system services from Fedora packages. Postgres is reachable from authorized clients through a single-PSK stunnel tunnel.

## How it works

- `Containerfile` builds on `quay.io/fedora/fedora-bootc:latest`. `setup.sh` installs `caddy`, `httpd`, `postgresql17-server`, and `stunnel`, then enables them as system services.
- On every push to `main`, GitHub Actions builds the image with `podman`, pushes it to `ghcr.io/varuniyer/bootc-setup:latest`, and rebuilds a GCP disk image as a recovery seed.
- The running VM updates itself from GHCR via the `bootc-fetch-apply-updates` timer. The GCP image is only for new VMs and disaster recovery.

## Filesystem

- `/usr`: immutable. The container image's root content, swapped atomically by the `bootc-fetch-apply-updates` timer. `/bin`, `/sbin`, `/lib`, `/lib64` are symlinks into `/usr`.
- `/etc`: transient tmpfs, repopulated from `/usr/etc` each boot. Runtime edits are lost on reboot. Bake persistent config into `/usr/etc` at image build.
- `/var`: mutable and persistent. Survives auto-updates and reboots. Service state (`/var/lib/webdav`, `/var/lib/pgsql/data`, `/var/log/caddy`) lives here. `/home` and `/root` are symlinks into `/var`.
- `/boot`, `/boot/efi`: managed by `bootupd`, updated as part of the `bootc-fetch-apply-updates` cycle.
- `/run`, `/tmp`: tmpfs, cleared each boot.
- `/sysroot`: read-only mount of the underlying ostree storage that backs bootc deployments. Not browsed directly.

`/etc` and `/sysroot` behavior is configured in `/usr/lib/ostree/prepare-root.conf` (ostree is bootc's storage layer on Fedora today).

## Access

Postgres is exposed via stunnel on `:5433` (TLS 1.3 PSK only). Any client with the PSK runs stunnel locally pointing `127.0.0.1:5432 -> varuniyer.net:5433`, then connects with `psql -h 127.0.0.1 -U experiments experiments`.

## Layout

- `Containerfile`: image definition; final stage runs `setup.sh` once.
- `setup.sh`: all build-time mutations (packages, sed, service enables).
- `post-startup.{sh,service}`: boot-time, idempotent. Creates `/var` state dirs with correct ownership, runs `postgresql-setup --initdb` and bootstraps the `experiments` role+db on first boot, refreshes Postgres configs each boot.
- `Caddyfile`, `webdav.conf`, `prepare-root.conf`, `bootc.json`, `stunnel/postgres.conf`: standalone configs, each COPY'd to their target paths.
- `upload-psk.sh`: one-time script that stores the stunnel PSK in GCP instance metadata. On next boot, `post-startup.sh` fetches it once and writes `/var/lib/stunnel/psk.txt` (persistent across reboots and updates).
- `postgresql/`: `postgresql.conf`, `pg_hba.conf` (copied into `/var/lib/pgsql/data/` each boot by `post-startup.sh`), and `bootstrap.sql` (run once on first-boot init to create the `experiments` role+db and lock down PUBLIC connect).
- `website/`: static site sources (Hugo).
- `build-disk.sh` and `.github/workflows/build.yml`: CI for GHCR push and GCP image build.
