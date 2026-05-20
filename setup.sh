#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Packages
# ----------------------------
dnf install -y caddy httpd postgresql18
dnf clean all


# ----------------------------
# System files
# ----------------------------
# Make /etc transient (tmpfs from /usr/etc each boot). /root is a
# symlink to /var/roothome; materialize it for dracut-install, then
# remove so the image's /var stays empty.
printf '\n[etc]\ntransient = true\n' >> /usr/lib/ostree/prepare-root.conf
KVER=$(basename /usr/lib/modules/*)
mkdir -p /var/roothome
dracut --no-hostonly --force --kver "$KVER" /usr/lib/modules/"$KVER"/initramfs.img
rmdir /var/roothome

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
# Users: experiments is ssh-forward-only into postgres
# ----------------------------
install -d /usr/share/experiments
useradd -M -d /usr/share/experiments -s /usr/sbin/nologin experiments
echo '/usr/sbin/nologin' >> /etc/shells


# ----------------------------
# SSH: root for shell, experiments for 5432 forward only
# ----------------------------
mkdir -p /etc/ssh/authorized_keys.d

cat > /etc/ssh/authorized_keys.d/root <<'EOF'
sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIAqvqfe/Qi/zXl2StxCA4piiBC2uuVAuAOC6u+TfMafsAAAACXNzaDp2dWx0cg==
sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJ1OrjNP1ysix4konD3sk7Gd+hdt+I+5sUc0SJNRQksjAAAACXNzaDp2dWx0cg==
EOF

cat > /etc/ssh/authorized_keys.d/experiments <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPuAduuMXxrNmk6xw9/0TNQ9K+Z0R9ODjGeyw+5+AcJB
EOF

printf 'AuthorizedKeysFile /etc/ssh/authorized_keys.d/%%u\nPermitRootLogin prohibit-password\n' \
    > /etc/ssh/sshd_config.d/30-authkeys.conf
printf 'Match User experiments\n    AllowTcpForwarding yes\n    PermitOpen 127.0.0.1:5432\n' \
    > /etc/ssh/sshd_config.d/40-experiments.conf


# ----------------------------
# httpd: bind to 127.0.0.1:8080 instead of the default :80
# ----------------------------
sed -i 's/^Listen .*/Listen 127.0.0.1:8080/' /etc/httpd/conf/httpd.conf


# ----------------------------
# Services
# ----------------------------
systemctl enable post-startup.service
systemctl enable bootc-fetch-apply-updates.timer
systemctl enable caddy.service
systemctl enable httpd.service
systemctl enable postgresql.service

mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/bootc upgrade --apply\n' \
    > /etc/systemd/system/bootc-fetch-apply-updates.service.d/override.conf

chmod +x /usr/libexec/post-startup.sh
