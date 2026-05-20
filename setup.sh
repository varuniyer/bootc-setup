#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Packages
# ----------------------------
dnf install -y caddy httpd postgresql17-server stunnel
dnf clean all


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
# httpd: drop the default Listen 80 so webdav.conf can own the bind
# ----------------------------
sed -i '/^Listen /d' /etc/httpd/conf/httpd.conf


# ----------------------------
# stunnel: lock down PSK file perms
# ----------------------------
chmod 0600 /etc/stunnel/psk.txt
chown root:root /etc/stunnel/psk.txt


# ----------------------------
# Services
# ----------------------------
systemctl enable post-startup.service \
                 caddy.service \
                 httpd.service \
                 postgresql.service \
                 stunnel@postgres.service \
                 bootc-fetch-apply-updates.timer

chmod +x /usr/libexec/post-startup.sh
