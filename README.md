# bootc-setup

bootc-based Fedora image for varuniyer.net. Runs the website, WebDAV, and a Postgres instance for experiments.

## How it works

- `Containerfile` builds on `quay.io/fedora/fedora-bootc:latest`. Caddy (website) runs as a systemd service. Apache `mod_dav` (WebDAV) and Postgres each run as a rootless podman container under their own dedicated user (`httpd`, `experiments`), so the two stacks are isolated by uid.
- On every push to `main`, GitHub Actions builds the image with `podman`, pushes it to `ghcr.io/varuniyer/bootc-setup:latest`, and rebuilds a GCP disk image as a recovery seed.
- The running VM updates itself from GHCR via the `bootc-fetch-apply-updates` timer. The GCP image is only for new VMs and disaster recovery.

## Filesystem

- `/usr`: immutable. The container image's root content, swapped atomically by the `bootc-fetch-apply-updates` timer. `/bin`, `/sbin`, `/lib`, `/lib64` are symlinks into `/usr`.
- `/etc`: transient tmpfs, repopulated from `/usr/etc` each boot. Runtime edits are lost on reboot. Bake persistent config into `/usr/etc` at image build.
- `/var`: mutable and persistent. Survives auto-updates and reboots. State directories (`/var/lib/webdav`, `/var/lib/postgres`, `/var/log/caddy`, `/var/lib/ssh`) live here. `/home` and `/root` are symlinks into `/var`.
- `/boot`, `/boot/efi`: managed by `bootupd`, updated as part of the `bootc-fetch-apply-updates` cycle.
- `/run`, `/tmp`: tmpfs, cleared each boot.
- `/sysroot`: read-only mount of the underlying ostree storage that backs bootc deployments. Not browsed directly.

`/etc` and `/sysroot` behavior is configured in `/usr/lib/ostree/prepare-root.conf` (ostree is bootc's storage layer on Fedora today).

## Layout

- `Containerfile`: image definition; final stage runs `setup.sh` once.
- `setup.sh`: all build-time mutations (users, unit enables, dirs, perms).
- `Caddyfile`: Caddy (website) config; runs as a systemd service.
- `webdav.container`, `httpd.conf`: rootless podman unit and config for Apache `mod_dav`, dropped into the `httpd` user's session.
- `postgres.container`, `postgresql.conf`, `pg_hba.conf`: rootless podman unit and configs for Postgres, dropped into the `experiments` user's session.
- `user-services.{service,sh}`: starts the per-user systemd instances at boot so the rootless containers come up without a login.
- `website/`: static site sources (Hugo).
- `build-disk.sh` and `.github/workflows/build.yml`: CI for GHCR push and GCP image build.
