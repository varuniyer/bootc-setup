# bootc-setup

bootc-based Fedora image for varuniyer.net. Runs the website, WebDAV, and a Postgres instance for experiments.

## How it works

- `Containerfile` builds on `quay.io/fedora/fedora-bootc:latest`. Caddy (website) runs as a systemd service. Apache `mod_dav` (WebDAV) and Postgres each run as a rootless podman container under their own dedicated user (`httpd`, `experiments`), so the two stacks are isolated by uid.
- On every push to `main`, GitHub Actions builds the image with `podman`, pushes it to `ghcr.io/varuniyer/bootc-setup:latest`, and rebuilds a GCP disk image as a recovery seed.
- The running VM updates itself from GHCR via the `bootc-fetch-apply-updates` timer. The GCP image is only for new VMs and disaster recovery.

## Layout

- `Containerfile`: image definition; final stage runs `setup.sh` once.
- `setup.sh`: all build-time mutations (users, unit enables, dirs, perms).
- `Caddyfile`: Caddy (website) config; runs as a systemd service.
- `webdav.container`, `httpd.conf`: rootless podman unit and config for Apache `mod_dav`, dropped into the `httpd` user's session.
- `postgres.container`, `postgresql.conf`, `pg_hba.conf`: rootless podman unit and configs for Postgres, dropped into the `experiments` user's session.
- `user-services.{service,sh}`: starts the per-user systemd instances at boot so the rootless containers come up without a login.
- `website/`: static site sources (Hugo).
- `build-disk.sh` and `.github/workflows/build.yml`: CI for GHCR push and GCP image build.
