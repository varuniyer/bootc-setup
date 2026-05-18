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
printf '\n[etc]\ntransient = true\n' >> /usr/lib/ostree/prepare-root.conf

# Persist sshd host keys in /var/lib/ssh. Symlinks at /etc/ssh hit a
# sshd_keygen_t -> etc_t:lnk_file unlink denial, so skip the bundled
# keygen units and read keys from /var/lib/ssh directly.
systemctl mask sshd-keygen@rsa.service \
               sshd-keygen@ecdsa.service \
               sshd-keygen@ed25519.service

mkdir -p /etc/ssh/sshd_config.d
printf 'HostKey /var/lib/ssh/ssh_host_rsa_key\nHostKey /var/lib/ssh/ssh_host_ecdsa_key\nHostKey /var/lib/ssh/ssh_host_ed25519_key\n' \
    > /etc/ssh/sshd_config.d/20-hostkeys.conf

cat > /usr/libexec/sshd-keygen-persist <<'EOF'
#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/ssh
for type in rsa ecdsa ed25519; do
    key="/var/lib/ssh/ssh_host_${type}_key"
    [ -s "$key" ] || ssh-keygen -q -t "$type" -f "$key" -C "" -N ""
done
chmod 0600 /var/lib/ssh/ssh_host_*_key
chmod 0644 /var/lib/ssh/ssh_host_*_key.pub
chcon -t sshd_key_t /var/lib/ssh/ssh_host_*
EOF
chmod +x /usr/libexec/sshd-keygen-persist

cat > /etc/systemd/system/sshd-keygen-persist.service <<'EOF'
[Unit]
Description=Generate persistent SSH host keys in /var/lib/ssh
Before=sshd.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/sshd-keygen-persist

[Install]
WantedBy=sshd.service
EOF
systemctl enable sshd-keygen-persist.service

mkdir -p /etc/bootc
echo '{ "image": "ghcr.io/varuniyer/bootc-setup:latest" }' > /etc/bootc/bootc.json


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
printf 'Match User experiments\n    AllowTcpForwarding yes\n    PermitOpen 127.0.0.1:5432 [::1]:5432\n' \
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
chmod +x /usr/libexec/user-services.sh
systemctl enable user-services.service
systemctl enable bootc-fetch-apply-updates.timer
systemctl enable caddy.service

mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/bootc upgrade --apply\n' \
    > /etc/systemd/system/bootc-fetch-apply-updates.service.d/override.conf
