# AGENTS.md

## Shell style

- Keep commands compact, 1-2 lines. Don't split into one-flag-per-line backslash continuations. The one exception is a gcloud command whose verb is `create` or `create-*`, like `gcloud compute instances create`, which puts every flag on its own line, a single flag included. A describe-or-create pair breaks after `||` even when the create takes no flags.

## Image structure

- The Containerfile final stage is COPY and ENV lines, then a single RUN line that marks /opt/scripts executable and runs setup.sh. Every other build-time mutation goes in setup.sh.
- Earlier stages may RUN whatever fetches or builds an artifact, like the site and postgresql-build stages, and the final stage takes each artifact through `COPY --from`.
- Every shipped file lives as a dedicated repo file COPY'd by the Containerfile. No heredocs or `printf > /path` for static file content inside setup.sh or boot scripts. Boot scripts may `printf` files they render from instance metadata.
- First-boot PostgreSQL work (initdb and the SQL that needs it) lives in bootstrap.sh, which boot-postgresql.sh calls until a bootstrap succeeds.

## Git

- Commit directly on `main`, audit and fix passes included. Create no branches.
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

- Code comments own code-local facts. The README describes operator-facing behavior and points at files. The README keeps the security-posture mechanisms (secrets out of argv, caddy_local.cil, the pghash-group file, sigstore attachments) even where a code comment states them.
- AGENTS.md keeps the facts behind its rules even where the README or setup.sh states them.
- The README's opening paragraph says that provision.sh puts every deployment-specific setting and secret the VM needs into instance metadata. The Deployment & Configuration intro holds the one list of them.
- The README's FAQ holds recovery edge cases and operator how-tos, like the recovery from a bootstrap that ran with a mistyped password.
- sandbox.conf is the one sandbox baseline, linked into every shipped unit's `.service.d/`, and holds the empty `CapabilityBoundingSet=`. Each unit states only its own differences. A unit that needs capabilities sets them in a `zz-capabilities.conf` drop-in, because the empty assignment resets the set, a drop-in parses after its unit file, and `zz-` sorts after sandbox.conf. The drop-in holds any `AmbientCapabilities=` the unit needs beside its `CapabilityBoundingSet=`, so one file states the unit's capabilities. Each drop-in's repo file carries its unit's name, as caddy/caddy-capabilities.conf and boot-root-capabilities.conf.
- bootstrap.sh runs initdb in a staging dir and renames it to `data` only after the SQL succeeds. boot-postgresql.sh gates on the hash file, which no unit removes from /run. /run is tmpfs, and every process that can read the file can read the same hash from pg_authid after bootstrap. boot-root.sh keeps the one first-boot test, and boot-root-capabilities.conf keeps CAP_DAC_READ_SEARCH for boot-root.service.
- A literal that a writer and its reader both name moves to one source only when a mismatch fails silently. The PostgreSQL data dir is such a literal and lives once, in pgdata.conf. The WireGuard port is another, because a mismatch falls back to DERP relays, and lives once, in tailscale/wireguard-port.env. Loud-failure pairs keep their literals at both ends: `127.0.0.1:8080`, `/run/caddy/env`, `/run/caddy/mta-sts`, `/etc/webdav/htpasswd`, `169.254.169.254`, and the hash file path.
- tailscaled.service and the nftables.service drop-in tailscale/nftables-wireguard-port.conf load wireguard-port.env with `EnvironmentFile=`, and provision.sh sources it. The drop-in passes `nft -D wireguard_port=...` in both `ExecStart=` and `ExecReload=`. Its `ExecReload=` loads the ruleset with `-f` rather than the stock `include` string, because nft 1.1.6 accepts `-D` only with `-f`. nftables.conf's opening `flush ruleset` does the stock string's flush.
- PGHOST on boot-postgresql.service and `unix_socket_directories` in postgresql.conf both state the socket dir. PostgreSQL 17, 18, and master offer no build option for it, and the user declined patching pg_config_manual.h. The socket stays in /run/postgresql, though only the PostgreSQL units use it.
- bootstrap.sh's `pg_ctl start` and postgresql.service both read the shipped configs in /etc/postgresql through `config_file`, and postgresql.conf sets `hba_file`. The comment above `hba_file` holds the fact that initdb's pg_hba.conf trusts every local connection, because the setting protects both servers. The data dir keeps initdb's unused config files.
- The server configs live in /etc/postgresql, named for the server like /etc/caddy, and the build's sharedir already takes /usr/share/postgresql. `boot-postgresql` then names only the bootstrap: its unit and script, its /run hash dir, and bootstrap.sql's /usr/share dir.
- postgresql.conf's sizing comment names Hyperdisk beside c4a-standard-1, because random_page_cost depends on the disk, not the machine type.
- The GCP firewall and nftables both hold the inbound allowlist, and bootstrap.sql's CONNECT revoke and pg_hba.conf both confine `experiments` to its own database. Each pair is two enforcement points.
- A file mode inside a directory that already confines access to the service's user or to the reading group is redundant, not a second enforcement point like the two pairs above. caddy and rclone-webdav carry no `UMask=` inside their 0700 dirs, and boot-root.sh writes the hash file without a chmod inside the 0750 root:pghash `RuntimeDirectory=`.
- The `experiments` role and database share a name, following PostgreSQL's convention.
- The GCP resources keep the `bootc-` prefix (bootc-ip, bootc-build, bootc-ci, bootc-seed, bootc-seed-upload, bootc-server) as a spelling of the repo's name, bootc-setup, not a second name. GCP requires a name to be unique only per resource type within its scope, so the prefix namespaces this stack within its project.
- Each unit states its own network need. Each unit that waits for network-online.target pulls it with `Wants=`, as systemd.special(7) prescribes, and orders `After=` it. caddy and boot-tailscale keep network-online.target although boot-root.service and tailscaled.service already pull it in.
- `Z /var/lib/caddy` relabels on every boot, so an image update that changes the SELinux policy cannot strand cert labels. caddy's state dir uses a tmpfiles `d` line and `ReadWritePaths=`, matching the PostgreSQL pattern, rather than `StateDirectory=`.
- The Caddyfile's global `servers` block sets `protocols h1 h2`. Both firewalls admit web traffic only on TCP 80 and 443, and the user chose to disable HTTP/3 over opening UDP 443.
- The README's API list is complete. CI's WIF auth works with sts.googleapis.com and cloudresourcemanager.googleapis.com disabled.
- Every final-stage `COPY --from` carries `--chown=0:0`. A new one needs the flag, because `--chown=0:0` is the only build step that makes root own files from another stage or image.
- A tmpfiles snippet's repo name matches its installed basename.
- `bootc container lint` is the last line of setup.sh, so CI fails on a lint error.
- Every `podman run` in provision.sh uses `--log-driver=none`, and every gcloud call that carries the GitHub PAT sets `CLOUDSDK_CORE_DISABLE_FILE_LOGGING=1`.
- The secrets-out-of-argv posture covers every script and container that handles a secret. build-and-publish.sh's `podman login` reads the token through `--password-stdin`, and every provision.sh container that sees a plaintext secret runs with `--network=none`, the skopeo key generator included.
- A line that states a tool's built-in default stays, unless it repeats a value the repo sets elsewhere. A unit omits a `Group=` that would repeat its user's primary group, which setup.sh's `useradd -g` sets. tailscaled.service passes no `--socket=`, because the built-in /var/run/tailscale/tailscaled.sock, which the CLI also uses, lies in the unit's `RuntimeDirectory=tailscale`. tailscaled's `--port=${WIREGUARD_PORT}` stays, because its built-in default is 0, a random port (tailscaled 1.104.4 `--help`), and the GCP firewall and nftables need a fixed one.
- sandbox.conf holds `IPAddressDeny=any`, and each unit that needs IP traffic adds its own `IPAddressAllow=`.
- run-as-postgres.conf holds the `User=` and `ReadWritePaths=` both PostgreSQL units share and links in beside sandbox.conf.
- setup.sh's link loop keeps its own unit list beside the Containerfile COPY. Deriving the list from units no RPM owns would also sandbox the base image's atomic-update-ca-trust and bootc-generic-growpart.
- containers/policy.json owns the image name, which carries the GitHub repository name. build-and-publish.sh reads the image name from that file, and provision.sh derives the repository name from it.
- build.env holds the names both provision.sh and CI read, including `WEBSITE_REPO`, which CI passes to the site stage as a build ARG. build.sh's 17.x and provision.sh's postgres:17-alpine stay independent of it, since SCRAM-SHA-256 password hashes share one format from PostgreSQL 10 on.
- `main` is hardcoded in provision.sh, because the workflow's `branches: [main]` cannot read a setting.
- bootc-setup.yaml keys `use-sigstore-attachments` on `default-docker:`. Per containers-registries.d(5), a lookup uses only the most precisely matching `docker:` scope, `default-docker:` applies when no `docker:` scope matches, and with neither, sigstore attachments are neither read nor written. At most one `default-docker` section may exist across all files. Fedora's /usr/share registries.d has an empty `default-docker:`, and Ubuntu 24.04's podman ships no registries.d file.
- Repository Layout entries point at the README section that states a claim instead of restating it.
- setup.sh's permission sweep also covers COPY'd content, since a umask-002 checkout makes it group-writable.
- A provision.sh variable that carries a metadata value takes the metadata key's name.
- A command substitution whose failure must stop a script is assigned on its own line. Inside another command's arguments or an && list, set -e does not see its failure.
- Only postgres pins its uid/gid (26), which keeps /var/lib/pgsql readable across image builds. caddy's floats between builds. The setup.sh comment gives that current reason rather than the migration from Fedora's packaged PostgreSQL.

## Open items

- A PostgreSQL bootstrap under sandbox.conf's `IPAddressDeny=any` has run only in containers. Check: the next fresh bootstrap, which runs only on reprovisioning, succeeds with boot-postgresql under `IPAddressDeny=any` and no `IPAddressAllow=`.
- Until the next reprovisioning, the deployed instance and its tailnet node keep the name `bootc`, so the commands that name `bootc-server` reach nothing. Check: after reprovisioning, `gcloud compute instances describe bootc-server` succeeds and the node appears as bootc-server in the tailnet.
