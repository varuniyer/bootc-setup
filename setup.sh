#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Packages
# ----------------------------
dnf install -y --setopt=install_weak_deps=False caddy postgresql17-server rclone gettext-envsubst
dnf remove -y openssh-server
dnf clean all

# Tailscale binaries are COPY'd from the official image and need SELinux labels.
restorecon /usr/bin/tailscale /usr/bin/tailscaled

mkdir /etc/rclone

# ----------------------------
# Rebuild initramfs so prepare-root.conf's [etc] transient takes effect.
# /root is a symlink to /var/roothome; materialize it for dracut-install,
# then remove so the image's /var stays empty.
# ----------------------------
KVER=$(basename /usr/lib/modules/*)
mkdir -p /var/roothome
dracut --no-hostonly --force --kver "$KVER" /usr/lib/modules/"$KVER"/initramfs.img
rmdir /var/roothome

# ----------------------------
# Build-time ownership/perms so post-startup-root needs no CAP_CHOWN at runtime.
# The `creds` group bridges root and postgres: root can chgrp to a group it's in
# without the cap, postgres reads files in the group via membership.
# ----------------------------
chown root:caddy /etc/caddy/Caddyfile
chmod 0640 /etc/caddy/Caddyfile

groupadd -r creds
usermod -aG creds root
usermod -aG creds postgres

# ----------------------------
# Services
# ----------------------------
systemctl enable systemd-sysctl nftables tailscaled post-startup-root post-startup-tailscale post-startup-postgresql rclone-webdav caddy postgresql bootc-fetch-apply-updates.timer
