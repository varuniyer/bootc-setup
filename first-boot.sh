#!/usr/bin/env bash
set -euo pipefail

user_systemctl() {
    local user="$1"; shift
    runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
        systemctl --user "$@"
}

for u in httpd experiments; do
    user_systemctl "$u" enable --now podman-auto-update.timer
done

user_systemctl httpd       start webdav.service
user_systemctl experiments start postgres.service
