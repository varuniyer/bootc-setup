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
tmp=$(mktemp)
jq --arg key /etc/containers/keys/cosign.pub '
  (.transports.docker //= {})
  | .transports.docker["ghcr.io/varuniyer/bootc-setup"] = [{
      "type": "sigstoreSigned",
      "keyPath": $key,
      "signedIdentity": { "type": "matchRepository" }
    }]
' /etc/containers/policy.json > "$tmp"
mv "$tmp" /etc/containers/policy.json


# ----------------------------
# Users (nologin for quadlet users; admin gets shell + passwordless wheel)
# ----------------------------
mkdir -p /var/spool/mail
useradd -m -d /var/home/httpd       -s /usr/sbin/nologin     httpd
useradd -m -d /var/home/experiments -s /usr/sbin/nologin     experiments
useradd -m -d /var/home/admin       -s /bin/bash -G wheel    admin
echo '/usr/sbin/nologin' >> /etc/shells

echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel-nopasswd
chmod 0440 /etc/sudoers.d/wheel-nopasswd

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

cat > /etc/ssh/authorized_keys.d/admin <<'EOF'
sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIAqvqfe/Qi/zXl2StxCA4piiBC2uuVAuAOC6u+TfMafsAAAACXNzaDp2dWx0cg==
sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJ1OrjNP1ysix4konD3sk7Gd+hdt+I+5sUc0SJNRQksjAAAACXNzaDp2dWx0cg==
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
printf '[Service]\nExecStart=\nExecStart=/usr/bin/bootc upgrade --apply\n' \
    > /etc/systemd/system/bootc-fetch-apply-updates.service.d/override.conf
