# AGENTS.md

## Shell style

- Keep commands compact, 1-2 lines. Don't split into one-flag-per-line backslash continuations. The one exception is a command that creates a cloud resource, like `gcloud compute instances create`, where one flag per line reads clearer.

## Image structure

- The Containerfile final stage is COPY and ENV lines, then a single RUN line that marks /opt/scripts executable and runs setup.sh. Every other build-time mutation goes in setup.sh.
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
- To pick up an update or recover from bad state, reboot the whole VM with `gcloud compute instances reset bootc` instead of reasoning about individual services.
- PostgreSQL and WebDAV are tailnet-only. Query PostgreSQL with `psql` and exercise WebDAV with `rclone <op> webdav:...`.

## Rulings

Settled during the 2026-11-10 audit and fix pass. A later audit treats each as decided.

- Code comments own code-local facts. The README describes operator-facing behavior and points at files.
- AGENTS.md keeps the facts behind its rules even where the README or setup.sh states them too.
- hardening.conf is the one sandbox baseline, linked into every shipped unit's `.service.d/`. Each unit states only its own differences.
- bootstrap.sh runs initdb in a staging dir and renames it to `data` only after the SQL succeeds. boot-postgresql.sh gates on the hash file, and boot-root.sh keeps the one first-boot test and CAP_DAC_READ_SEARCH.
- PGHOST on boot-postgresql.service and `unix_socket_directories` in postgresql.conf both state the socket dir. PostgreSQL 17, 18, and master offer no build option for it, and patching pg_config_manual.h was declined.
- The GCP firewall and nftables both hold the inbound allowlist as two enforcement points.
- The `experiments` role and database share a name, following PostgreSQL's convention.
- `Z /var/lib/caddy` relabels on every boot, so an image update that changes the policy cannot strand cert labels.
- The README's API list is complete. CI's WIF auth works with sts.googleapis.com and cloudresourcemanager.googleapis.com disabled.
- Every final-stage `COPY --from` carries `--chown=0:0`. A new one needs the flag, since no ownership sweep remains.
- A tmpfiles snippet's repo name matches its installed basename.
- `bootc container lint` is the last line of setup.sh, so CI fails on a lint error.
- Every `podman run` in provision.sh uses `--log-driver=none`, and every gcloud call that carries the GitHub PAT sets `CLOUDSDK_CORE_DISABLE_FILE_LOGGING=1`.

## Open items

- fstab moved from /usr/etc to /etc. Check: the first boot on the new image shows bootloader-update.service finding /boot in the serial log.
- The boot-unit renames, hardening.conf (with PrivateTmp=disconnected for all seven units), and the staged bootstrap were verified only in containers. Check: the first boot's serial log shows boot-root, boot-tailscale, boot-postgresql, and every service active, and tailnet psql still connects.
- One-time migration for the renames, in order. Create `gs://bootc-seed-upload` with the bootc-ci objectAdmin binding (provision.sh's two bucket commands). Re-add `ts-oauth-secret` to the VM's metadata, because the new marker path re-runs `tailscale up`. Push. Point the `bootc-build` scheduler job's `--uri` at `build-and-publish.yml`. After the update boots and tailnet access checks out, remove `ts-oauth-secret` again. Then delete the old `bootc` image and `gs://bootc` bucket.
- One-time migration for the website split, in order. Create `varuniyer/website` as a public repo, since the `website` stage fetches its tarball unauthenticated. Run README's PAT snippet, which sets its `GH_WORKFLOW_TOKEN` secret and refreshes the `bootc-build` job's header with the same PAT. Push its main and wait for the `static` branch. Then push bootc-setup, whose builds fail while that branch is missing.
