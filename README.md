# bootc-setup

bootc-based Fedora image for varuniyer.net. Runs the website, WebDAV, and a Postgres instance for experiments.

## How it works

- `Containerfile` builds on `quay.io/fedora/fedora-bootc:latest` and bakes in Caddy (web), Apache `mod_dav` (WebDAV), and Postgres.
- On every push to `main`, GitHub Actions builds the image with `podman`, pushes it to `ghcr.io/varuniyer/bootc-setup:latest`, and rebuilds a GCP disk image as a recovery seed.
- The running VM updates itself from GHCR via the `bootc-fetch-apply-updates` timer. The GCP image is only for new VMs and disaster recovery.

## Layout

- `Containerfile`: image definition; final stage runs `setup.sh` once.
- `setup.sh`: all build-time mutations (users, units, configs).
- `Caddyfile`, `httpd.conf`, `postgresql.conf`, `pg_hba.conf`: service configs.
- `postgres.container`, `webdav.container`: Quadlet units.
- `user-services.{service,sh}`: boots user-mode services after `user@.service`.
- `website/`: static site sources (Hugo).
- `build-disk.sh` and `.github/workflows/build.yml`: CI for GHCR push and GCP image build.
