#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Users
# ----------------------------
id -u httpd &>/dev/null || \
    useradd -m -d /var/home/httpd -s /usr/sbin/nologin httpd

id -u experiments &>/dev/null || \
    useradd -m -d /var/home/experiments -s /usr/sbin/nologin experiments

# ----------------------------
# Enable linger
# ----------------------------
loginctl enable-linger httpd
loginctl enable-linger experiments

# ----------------------------
# SSH key for experiments
# ----------------------------
mkdir -p /var/home/experiments/.ssh

# 👉 Replace this with your public key
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPuAduuMXxrNmk6xw9/0TNQ9K+Z0R9ODjGeyw+5+AcJB" \
    > /var/home/experiments/.ssh/authorized_keys

chown -R experiments:experiments /var/home/experiments/.ssh
chmod 0700 /var/home/experiments/.ssh
chmod 0600 /var/home/experiments/.ssh/authorized_keys

# ----------------------------
# WebDAV
# ----------------------------
mkdir -p /var/lib/webdav/data
mkdir -p /var/lib/webdav/lock

chown -R httpd:httpd /var/lib/webdav
chmod 0700 /var/lib/webdav
chmod 0700 /var/lib/webdav/data
chmod 0700 /var/lib/webdav/lock

touch /var/lib/webdav/lock/lockdb
chown httpd:httpd /var/lib/webdav/lock/lockdb
chmod 0600 /var/lib/webdav/lock/lockdb

# ----------------------------
# PostgreSQL
# ----------------------------
mkdir -p /var/lib/postgres/experiments

chown -R experiments:experiments /var/lib/postgres
chmod 0700 /var/lib/postgres
chmod 0700 /var/lib/postgres/experiments

# ----------------------------
# Caddy logs
# ----------------------------
mkdir -p /var/log/caddy
chown -R caddy:caddy /var/log/caddy
chmod 0750 /var/log/caddy

# ----------------------------
# Enable auto-update timers
# ----------------------------
su - httpd -c "systemctl --user enable podman-auto-update.timer"
su - experiments -c "systemctl --user enable podman-auto-update.timer"

echo "✅ Setup complete"
