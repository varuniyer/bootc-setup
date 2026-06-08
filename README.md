# bootc-setup

This repository defines a bootc-based Fedora image for [varuniyer.net](https://varuniyer.net) that runs the website, WebDAV, MTA-STS, and a Postgres 17 instance for experiments. Caddy listens on port 443. A layer4 listener wrapper intercepts direct-TLS Postgres connections for `db.varuniyer.net` using SNI, ALPN `postgresql`, and a source-IP allowlist. The listener terminates TLS using a publicly trusted ACME certificate for `db.varuniyer.net`, and proxies to local Postgres. The filesystem layout follows the conventions described in the [Fedora bootc documentation](https://docs.fedoraproject.org/en-US/bootc/).

## How it works

- `Containerfile` builds on `quay.io/fedora/fedora-bootc:latest`. A separate stage uses `xcaddy` to compile Caddy with the `layer4` and `webdav` plugins. `setup.sh` installs `caddy` (for the user, group, and systemd unit) and `postgresql17-server`, swaps in the custom caddy binary, removes `openssh-server`, then enables the services.
- On a recurring schedule, GitLab CI builds the image with `podman`, pushes it to `registry.gitlab.com/varuniyer/bootc-setup:latest`, and rebuilds a GCP disk image as a recovery seed.
- The running VM updates itself from the GitLab registry via the `bootc-fetch-apply-updates` timer. The GCP image is only for new VMs and disaster recovery.

## Access

Postgres is exposed via Caddy's `layer4` listener wrapper on `db.varuniyer.net:443`. Caddy terminates TLS using a publicly trusted ACME certificate for `db.varuniyer.net`. Then, Caddy forwards plain Postgres protocol bytes to Postgres on localhost. Database access is limited to source IPs in the `postgres-ip-allowlist`.

Authorized clients connect with:

```bash
psql 'postgresql://experiments:<PASSWORD>@db.varuniyer.net:443/experiments?sslmode=verify-full&sslnegotiation=direct&sslrootcert=system'
```

`sslnegotiation=direct` requires libpq 17 on the client.

## Layout

- `Containerfile`: image definition. Multi-stage build includes an `xcaddy` step that produces a custom caddy binary with `layer4` + `webdav` plugins. Final stage runs `setup.sh` once.
- `setup.sh`: all build-time mutations. Installs packages, swaps in the custom caddy binary, creates `/var` state directories with correct ownership and permissions, creates the `creds` group bridging root and postgres, and enables services.
- `post-startup-root.{sh,service}`: root-side boot setup. Renders `/etc/caddy/Caddyfile` from the `/usr/etc` template using instance metadata, and on first boot stages the Postgres SCRAM verifier at `/run/post-startup/hash`.
- `post-startup.{sh,service}`: postgres-side boot setup. Runs `initdb` on first boot, refreshes Postgres configs from `/usr/share/postgres/` each boot, and invokes `bootstrap.sh` when a staged SCRAM verifier is present.
- `bootstrap.sh`: applies the first-boot SQL from `/usr/share/postgres/bootstrap.sql`, setting the `experiments` role password from the staged SCRAM verifier.
- `Caddyfile`, `prepare-root.conf`, `bootc.json`: standalone configs copied to their target paths. `Caddyfile` is a template whose metadata-backed variables are rendered by `post-startup-root.sh`.
- `provision.sh`: collects the Postgres/WebDAV passwords and Postgres IP allowlist, hashes passwords locally, and creates the GCP instance with the resulting hashes and allowlist in metadata.
- `postgresql/`: `postgresql.conf`, `pg_hba.conf` (copied into `/var/lib/pgsql/data/` each boot by `post-startup.sh`), and `bootstrap.sql` (role+db creation SQL run once on first boot by `bootstrap.sh`).
- `website/`: static site sources (Hugo).
- `build-and-deploy.sh` and `.gitlab-ci.yml`: CI for image push and GCP image build.
