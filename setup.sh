#!/usr/bin/env bash
set -euo pipefail

# Nothing ever logs into the VM, so it ships without SSH or host keys.
dnf remove -y openssh-server openssh-clients
rm -rf /etc/ssh

# COPY'd binaries need SELinux labels.
restorecon -R /usr/bin /usr/lib64

# Users for the services shipped outside RPM. uid/gid 26 matches the Fedora
# postgres package so existing /var/lib/pgsql data stays readable.
groupadd -r caddy
useradd -r -g caddy -d /var/lib/caddy -s /usr/sbin/nologin caddy
groupadd -r -g 26 postgres
useradd -r -u 26 -g postgres -d /var/lib/pgsql -s /usr/sbin/nologin postgres

mkdir /etc/rclone

# Rebuild initramfs so prepare-root.conf's [etc] transient takes effect.
# /root is a symlink to /var/roothome; materialize it for dracut-install,
# then remove so the image's /var stays empty.
KVER=$(basename /usr/lib/modules/*)
mkdir -p /var/roothome
dracut --no-hostonly --force --kver "$KVER" /usr/lib/modules/"$KVER"/initramfs.img
rmdir /var/roothome

# The base image ships group-writable files that its own RPMs declare 0644.
# Strip stray write bits from everything COPY'd or inherited.
find /usr /etc /opt \( -type f -o -type d \) -perm /022 -exec chmod go-w {} +

# COPY --from preserves source-image ownership, so root reclaims those files.
find /usr /opt ! -user root -exec chown root:root {} +

# Build-time ownership/perms so post-startup-root needs no CAP_CHOWN at runtime.
# The `creds` group bridges root and postgres: root can chgrp to a group it's in
# without the cap, postgres reads files in the group via membership.
chown root:caddy /etc/caddy/Caddyfile
chmod 0640 /etc/caddy/Caddyfile

groupadd -r creds
usermod -aG creds root
usermod -aG creds postgres

systemctl enable nftables tailscaled post-startup-root post-startup-tailscale post-startup-postgresql rclone-webdav caddy postgresql bootc-fetch-apply-updates.timer
