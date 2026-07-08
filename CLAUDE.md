# CLAUDE.md

## Prose and writing

- Never use em dashes, semicolons, "rather than", or "did not" in any prose (paper text, replies, commit messages). Split into sentences or reword.
- Documentation describes the current protocol directly. Delete descriptions of superseded intermediate states instead of narrating the history.
- Write README and other doc prose as complete sentences with explicit subjects. Bullet list items are exempt.
- Skip filler qualifiers like "ad-hoc", "various", and "miscellaneous".
- Cap shell script header comments at 2 lines. State only the non-obvious why.

## Shell style

- Keep commands compact, 1-2 lines. Don't split into one-flag-per-line backslash continuations. Exception: resource creation commands like `gcloud compute instances create`, where one flag per line reads clearer.

## Image structure

- The Containerfile final stage is COPY and ENV lines, then a single RUN line that marks /opt/scripts executable and runs setup.sh. Every other build-time mutation goes in setup.sh. No other RUN lines in the final stage.
- Every shipped file lives as a dedicated repo file COPY'd by the Containerfile. No heredocs or `printf > /path` file content inside setup.sh or post-startup scripts.
- First-boot-only postgres work (initdb-dependent SQL) lives in bootstrap.sh, called by post-startup-postgresql.sh on first boot.

## Git

- Commit when asked, but never `git push`. Pushing needs a Yubikey tap, so the user pushes manually.
- Run `git log -1` before any `git commit --amend`. The user makes commits between turns, so HEAD may not be the commit you expect.
- Remove tracked files with `git rm`, not plain `rm`.
- When one "commit" instruction covers several changes from the conversation, write one combined commit instead of per-subsystem splits.

## CI

- CI builds with `podman build --layers=false`. Don't suggest docker buildx, `--cache-from`, or other layer caching. The layers are too small for caching to pay off.

## Operating the running VM

- Nothing ever logs into the VM. There is no sshd, no serial getty login, and no user password. Never propose running commands on the VM, including live /etc edits. Every fix lands by committing to the repo and letting the image update path apply it.
- Inspect runtime state through the read-only serial log: `gcloud compute instances get-serial-port-output bootc`. Don't rebuild the image locally to answer questions about deployed state.
- To pick up an update or recover from bad state, reboot the whole VM with `gcloud compute instances reset bootc` instead of reasoning about individual services.
- PostgreSQL and WebDAV are tailnet-only. Query postgres with `psql` and exercise WebDAV with `rclone <op> webdav:...`.
