#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Packages
# ----------------------------
dnf install -y caddy
dnf clean all


# ----------------------------
# System files
# ----------------------------
mkdir -p /etc/bootc
echo '{ "image": "ghcr.io/varuniyer/bootc-setup:latest" }' > /etc/bootc/bootc.json

mkdir -p /etc/containers/registries.d
printf 'docker:\n  ghcr.io:\n    use-sigstore-attachments: true\n' \
    > /etc/containers/registries.d/ghcr.yaml


# ----------------------------
# Container signature policy
# ----------------------------
podman image trust set -t accept docker.io/library/httpd
podman image trust set -t accept docker.io/library/postgres
podman image trust set -t sigstoreSigned \
    --pubkeysfile /etc/containers/keys/cosign.pub \
    ghcr.io/varuniyer/bootc-setup


# ----------------------------
# Users (nologin shells; experiments tunnels postgres over SSH)
# ----------------------------
mkdir -p /var/spool/mail
useradd -m -d /var/home/httpd       -s /usr/sbin/nologin httpd
useradd -m -d /var/home/experiments -s /usr/sbin/nologin experiments
echo '/usr/sbin/nologin' >> /etc/shells

# Rootless container userns mapping (non-overlapping 64k ranges per user)
printf 'httpd:100000:65536\nexperiments:165536:65536\n' >> /etc/subuid
printf 'httpd:100000:65536\nexperiments:165536:65536\n' >> /etc/subgid


# ----------------------------
# SSH (key in /etc so it updates on bootc upgrade; experiments port-forward only)
# ----------------------------
mkdir -p /etc/ssh/authorized_keys.d /etc/ssh/sshd_config.d

cat > /etc/ssh/authorized_keys.d/experiments <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPuAduuMXxrNmk6xw9/0TNQ9K+Z0R9ODjGeyw+5+AcJB
EOF

printf 'AuthorizedKeysFile /etc/ssh/authorized_keys.d/%%u\n' \
    > /etc/ssh/sshd_config.d/30-authkeys.conf
printf 'Match User experiments\n    AllowTcpForwarding yes\n    PermitOpen 127.0.0.1:5432\n' \
    > /etc/ssh/sshd_config.d/40-experiments.conf


# ----------------------------
# Lingering for quadlet users
# ----------------------------
mkdir -p /var/lib/systemd/linger
touch /var/lib/systemd/linger/httpd /var/lib/systemd/linger/experiments


# ----------------------------
# State directories (baked into /usr/share/factory/var)
# ----------------------------
mkdir -p /var/lib/webdav/data /var/lib/webdav/lock \
         /var/lib/postgres/experiments \
         /var/log/caddy

chown -R httpd:httpd /var/lib/webdav
chmod 0700 /var/lib/webdav /var/lib/webdav/data /var/lib/webdav/lock
touch /var/lib/webdav/lock/lockdb
chown httpd:httpd /var/lib/webdav/lock/lockdb
chmod 0600 /var/lib/webdav/lock/lockdb

chown -R experiments:experiments /var/lib/postgres
chmod 0700 /var/lib/postgres /var/lib/postgres/experiments

chown -R caddy:caddy /var/log/caddy
chmod 0750 /var/log/caddy


# ----------------------------
# Services and timers
# ----------------------------
chmod +x /usr/libexec/first-boot.sh
systemctl enable first-boot.service
systemctl enable bootc-fetch-apply-updates.timer
systemctl enable caddy.service

mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/bootc-fetch-apply-updates --reboot\n' \
    > /etc/systemd/system/bootc-fetch-apply-updates.service.d/override.conf
