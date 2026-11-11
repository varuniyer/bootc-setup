# AGENTS.md

## Shell style

- Keep commands compact, 1-2 lines. Don't split into one-flag-per-line backslash continuations. The one exception is a command that creates a cloud resource, like `gcloud compute instances create`, which puts every flag on its own line, a single flag included. A describe-or-create pair breaks after `||` even when the create takes no flags.

## Image structure

- The Containerfile final stage is COPY and ENV lines, then a single RUN line that marks /opt/scripts executable and runs setup.sh. Every other build-time mutation goes in setup.sh.
- Earlier stages may RUN whatever fetches or builds an artifact, like the site and postgresql-build stages, and the final stage takes each artifact through `COPY --from`.
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
- Inspect runtime state through the read-only serial log: `gcloud compute instances get-serial-port-output bootc-server`. Don't rebuild the image locally to answer questions about deployed state.
- bootc-fetch-apply-updates.timer fetches each update by itself, 1 to 3 hours after boot and every 8 to 10 hours after that, and reboots the VM to apply it. A reset boots only an update the timer has already staged. To recover from bad state, reboot the whole VM with `gcloud compute instances reset bootc-server` instead of reasoning about individual services.
- PostgreSQL and WebDAV are tailnet-only. Query PostgreSQL with `psql` and exercise WebDAV with `rclone <op> webdav:...`.

## Rulings

Settled during the 2026-11-10 audit and fix passes. A later audit treats each as decided.

- Code comments own code-local facts. The README describes operator-facing behavior and points at files. The README keeps the security-posture mechanisms (secrets out of argv, caddy_local.cil, the pghash-group file, sigstore attachments) even where a code comment states them too.
- AGENTS.md keeps the facts behind its rules even where the README or setup.sh states them too.
- sandbox.conf is the one sandbox baseline, linked into every shipped unit's `.service.d/`, and holds the empty `CapabilityBoundingSet=`. Each unit states only its own differences. A unit that needs capabilities sets them in a `zz-capabilities.conf` drop-in, because the empty assignment resets the set, a drop-in parses after its unit file, and `zz-` sorts after sandbox.conf. Each drop-in's repo file carries its unit's name, as caddy/caddy-capabilities.conf and boot-root-capabilities.conf.
- bootstrap.sh runs initdb in a staging dir and renames it to `data` only after the SQL succeeds. boot-postgresql.sh gates on the hash file, which no unit removes from /run. /run is tmpfs, and every process that can read the file can read the same hash from pg_authid after bootstrap. boot-root.sh keeps the one first-boot test, and boot-root-capabilities.conf keeps CAP_DAC_READ_SEARCH for boot-root.service.
- A literal that a writer and its reader both name moves to one source only when a mismatch fails silently. The PostgreSQL data dir is such a literal and lives once, in pgdata.conf. Loud-failure pairs keep their literals at both ends: `127.0.0.1:8080`, `/run/caddy/env`, `/run/caddy/mta-sts`, `/etc/webdav/htpasswd`, `169.254.169.254`, and the hash file path.
- PGHOST on boot-postgresql.service and `unix_socket_directories` in postgresql.conf both state the socket dir. PostgreSQL 17, 18, and master offer no build option for it, and the user declined patching pg_config_manual.h. The socket stays in /run/postgresql, though only the PostgreSQL units use it today.
- Both PostgreSQL server starts read the shipped configs in /usr/share/boot-postgresql through `config_file`, and postgresql.conf sets `hba_file`. The data dir keeps initdb's unused config files.
- The GCP firewall and nftables both hold the inbound allowlist, and bootstrap.sql's CONNECT revoke and pg_hba.conf both confine `experiments` to its own database. Each pair is two enforcement points.
- The `experiments` role and database share a name, following PostgreSQL's convention.
- Each unit states its own network need. caddy and boot-tailscale keep network-online.target although boot-root.service and tailscaled.service already pull it in.
- `Z /var/lib/caddy` relabels on every boot, so an image update that changes the SELinux policy cannot strand cert labels. caddy's state dir uses a tmpfiles `d` line and `ReadWritePaths=`, matching the PostgreSQL pattern, rather than `StateDirectory=`.
- The README's API list is complete. CI's WIF auth works with sts.googleapis.com and cloudresourcemanager.googleapis.com disabled.
- Every final-stage `COPY --from` carries `--chown=0:0`. A new one needs the flag, because `--chown=0:0` is the only build step that makes root own files from another stage or image.
- A tmpfiles snippet's repo name matches its installed basename.
- `bootc container lint` is the last line of setup.sh, so CI fails on a lint error.
- Every `podman run` in provision.sh uses `--log-driver=none`, and every gcloud call that carries the GitHub PAT sets `CLOUDSDK_CORE_DISABLE_FILE_LOGGING=1`.
- A line that states a tool's built-in default stays, unless it repeats a value the repo sets elsewhere. A unit omits a `Group=` that would repeat its user's primary group, which setup.sh's `useradd -g` sets. tailscaled's `--port=41641` stays, because its built-in default is 0, a random port (tailscaled 1.104.4 `--help`), and the GCP firewall and nftables need a fixed one.
- sandbox.conf holds `IPAddressDeny=any`, and each unit that needs IP traffic adds its own `IPAddressAllow=`. run-as-postgres.conf holds the `User=` and `ReadWritePaths=` both PostgreSQL units share and links in beside sandbox.conf.
- setup.sh's link loop keeps its own unit list beside the Containerfile COPY. Deriving the list from units no RPM owns would also sandbox the base image's atomic-update-ca-trust and bootc-generic-growpart.
- containers/policy.json owns the GitHub repository name. provision.sh and build-and-publish.sh derive it from that file.
- build.env holds the names both provision.sh and CI read, including `WEBSITE_REPO`, which CI passes to the site stage as a build ARG. build.sh's 17.x and provision.sh's postgres:17-alpine stay independent of it, since SCRAM-SHA-256 verifiers share one format from PostgreSQL 10 on.
- `main` is hardcoded in provision.sh, because the workflow's `branches: [main]` cannot read a setting.
- bootc-setup.yaml keys `use-sigstore-attachments` on `default-docker:`. Per containers-registries.d(5), a lookup uses only the most precisely matching `docker:` scope, `default-docker:` applies when no `docker:` scope matches, and with neither, sigstore attachments are neither read nor written. At most one `default-docker` section may exist across all files. Fedora's /usr/share registries.d has an empty `default-docker:`, and Ubuntu 24.04's podman ships no registries.d file.
- Repository Layout entries point at the README section that states a claim instead of restating it.
- setup.sh's permission sweep also covers COPY'd content, since a umask-002 checkout makes it group-writable.
- A provision.sh variable that carries a metadata value takes the metadata key's name.
- A command substitution whose failure must stop a script is assigned on its own line. Inside another command's arguments or an && list, set -e does not see its failure.
- Only postgres pins its uid/gid (26). caddy's floats between builds.

## Open items

- A PostgreSQL bootstrap under sandbox.conf's `IPAddressDeny=any` has run only in containers. Check: the next fresh bootstrap, which runs only on reprovisioning, succeeds with boot-postgresql under `IPAddressDeny=any` and no `IPAddressAllow=`.
- Until the next reprovisioning, the deployed instance and its tailnet node keep the name `bootc`, so the commands that name `bootc-server` reach nothing. Check: after reprovisioning, `gcloud compute instances describe bootc-server` succeeds and the node appears as bootc-server in the tailnet.
