#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Packages
# ----------------------------
dnf install -y --setopt=install_weak_deps=False caddy postgresql17-server gettext-envsubst
# dnf remove -y openssh-server

mkdir /root/.ssh
cat > /root/.ssh/authorized_keys <<'EOF'
sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJ1OrjNP1ysix4konD3sk7Gd+hdt+I+5sUc0SJNRQksjAAAACXNzaDp2dWx0cg==
EOF

dnf clean all

# Replace stock caddy with custom build (layer4 + webdav plugins).
mv /tmp/caddy.custom /usr/bin/caddy
restorecon /usr/bin/caddy

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
mkdir -p /var/lib/webdav/data
chmod 0700 /var/lib/webdav /var/lib/webdav/data
chown -R caddy:caddy /var/lib/webdav

chown root:caddy /etc/caddy/Caddyfile
chmod 0640 /etc/caddy/Caddyfile

groupadd -r creds
usermod -aG creds root
usermod -aG creds postgres

# ----------------------------
# Services
# ----------------------------
# systemctl enable nftables.service
systemctl enable post-startup-root.service post-startup.service caddy.service postgresql.service bootc-fetch-apply-updates.timer
