#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Packages
# ----------------------------
dnf install -y caddy postgresql17-server
dnf remove -y openssh-server
dnf clean all

# Replace stock caddy with custom build (layer4 + webdav plugins).
mv /tmp/caddy.custom /usr/bin/caddy


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
# Services
# ----------------------------
systemctl enable post-startup.service caddy.service postgresql.service bootc-fetch-apply-updates.timer

chmod +x /usr/libexec/post-startup.sh /usr/libexec/bootstrap.sh
