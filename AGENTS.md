# AGENTS.md

## Shell style

- Keep commands compact, 1-2 lines. Don't split into one-flag-per-line backslash continuations. The one exception is a command that creates a cloud resource, like `gcloud compute instances create`, where one flag per line reads clearer.

## Image structure

- The Containerfile final stage is COPY and ENV lines, then a single RUN line that marks /opt/scripts executable and runs setup.sh. Every other build-time mutation goes in setup.sh.
- Earlier stages may RUN whatever fetches or builds an artifact, like the website and postgresql-build stages, and the final stage takes each artifact through `COPY --from`.
- Every shipped file lives as a dedicated repo file COPY'd by the Containerfile. No heredocs or `printf > /path` for static file content inside setup.sh or boot scripts. Boot scripts may `printf` files they render from instance metadata.
- First-boot PostgreSQL work (initdb and the SQL that needs it) lives in bootstrap.sh, which boot-postgresql.sh calls until a bootstrap succeeds.

## Git

- Run `git log -1` before any `git commit --amend`. The user makes commits between turns, so HEAD may not be the commit you expect.
- Remove tracked files with `git rm`, not plain `rm`.
- When one "commit" instruction covers several changes from the conversation, write one combined commit instead of per-subsystem splits.

## CI

- CI builds with `podman build --layers=false`. Don't suggest docker buildx, `--cache-from`, or other layer caching. The layers are too small for caching to pay off.

## Operating the running VM

- Nothing ever logs into the VM. There is no sshd, no serial getty login, and no user password. Never propose running commands on the VM, including live /etc edits. Every fix lands by committing to the repo and letting an image update apply it.
- Inspect runtime state through the read-only serial log: `gcloud compute instances get-serial-port-output bootc`. Don't rebuild the image locally to answer questions about deployed state.
- bootc-fetch-apply-updates.timer fetches each update by itself, 1 to 3 hours after boot and every 8 to 10 hours after that, and reboots the VM to apply it. A reset boots only an update the timer has already staged. To recover from bad state, reboot the whole VM with `gcloud compute instances reset bootc` instead of reasoning about individual services.
- PostgreSQL and WebDAV are tailnet-only. Query PostgreSQL with `psql` and exercise WebDAV with `rclone <op> webdav:...`.

## Rulings

Settled during the 2026-11-10 audit and fix passes. A later audit treats each as decided.

- Code comments own code-local facts. The README describes operator-facing behavior and points at files.
- AGENTS.md keeps the facts behind its rules even where the README or setup.sh states them too.
- hardening.conf is the one sandbox baseline, linked into every shipped unit's `.service.d/`. Each unit states only its own differences.
- bootstrap.sh runs initdb in a staging dir and renames it to `data` only after the SQL succeeds. boot-postgresql.sh gates on the hash file. boot-root.sh keeps the one first-boot test, and boot-root.service keeps CAP_DAC_READ_SEARCH.
- PGHOST on boot-postgresql.service and `unix_socket_directories` in postgresql.conf both state the socket dir. PostgreSQL 17, 18, and master offer no build option for it, and the user declined patching pg_config_manual.h.
- The GCP firewall and nftables both hold the inbound allowlist as two enforcement points.
- The `experiments` role and database share a name, following PostgreSQL's convention.
- `Z /var/lib/caddy` relabels on every boot, so an image update that changes the policy cannot strand cert labels.
- The README's API list is complete. CI's WIF auth works with sts.googleapis.com and cloudresourcemanager.googleapis.com disabled.
- Every final-stage `COPY --from` carries `--chown=0:0`. A new one needs the flag, because `--chown=0:0` is the only build step that makes root own files from another stage or image.
- A tmpfiles snippet's repo name matches its installed basename.
- `bootc container lint` is the last line of setup.sh, so CI fails on a lint error.
- Every `podman run` in provision.sh uses `--log-driver=none`, and every gcloud call that carries the GitHub PAT sets `CLOUDSDK_CORE_DISABLE_FILE_LOGGING=1`.
- A line that states a tool's built-in default stays, unless it repeats a value the repo sets elsewhere. `Group=` went because setup.sh's `useradd -g` sets the primary group.
- hardening.conf holds `IPAddressDeny=any`, and each unit adds its own `IPAddressAllow=`. postgresql-service.conf holds the lines both PostgreSQL units share and links in beside hardening.conf.
- setup.sh's link loop keeps its own unit list beside the Containerfile COPY. Deriving the list from units no RPM owns would also sandbox the base image's atomic-update-ca-trust and bootc-generic-growpart.
- containers/policy.json owns the GitHub repository name. provision.sh and build-and-publish.sh derive it from that file.
- build.env holds the names both provision.sh and CI read, including `WEBSITE_REPO`, which CI passes to the website stage as a build ARG.
- `main` is hardcoded in provision.sh, because the workflow's `branches: [main]` cannot read a setting.
- Every flag of a cloud-resource create command sits on its own line, a single flag included.
- bootc-setup.yaml keys `use-sigstore-attachments` on `default-docker:`. Verification and attachment writes match the per-image key. Fedora's /usr/share registries.d has an empty `default-docker:`, and Ubuntu 24.04's podman ships no registries.d file.
- Repository Layout entries point at the README section that states a claim instead of restating it.
- setup.sh's permission sweep also covers COPY'd content, since a umask-002 checkout makes it group-writable.
- A provision.sh variable that carries a metadata value takes the metadata key's name.

## Open items

- hardening.conf's `IPAddressDeny=any` and each unit's `IPAddressAllow=` were verified only in containers. Check: the first boot's serial log on the new image shows boot-root fetching metadata under its `IPAddressAllow=169.254.169.254` filter, and boot-tailscale, tailscaled, and caddy working. The next fresh PostgreSQL bootstrap, which runs only on reprovisioning, succeeds with boot-postgresql under `IPAddressDeny=any` and no `IPAddressAllow=`.
