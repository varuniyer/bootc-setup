#!/usr/bin/env bash
set -euo pipefail

id -u httpd &>/dev/null || \
    useradd -m -d /var/home/httpd -s /usr/sbin/nologin httpd

id -u experiments &>/dev/null || \
    useradd -m -d /var/home/experiments -s /usr/sbin/nologin experiments


# ----------------------------
# SSH keys (experiments)
# ----------------------------
mkdir -p /var/home/experiments/.ssh

echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPuAduuMXxrNmk6xw9/0TNQ9K+Z0R9ODjGeyw+5+AcJB" \
    > /var/home/experiments/.ssh/authorized_keys

chown -R experiments:experiments /var/home/experiments/.ssh
chmod 0700 /var/home/experiments/.ssh
chmod 0600 /var/home/experiments/.ssh/authorized_keys


# ----------------------------
# SSH keys (httpd / rsync backups)
# ----------------------------
mkdir -p /var/home/httpd/.ssh

cat > /var/home/httpd/.ssh/authorized_keys <<'EOF'
sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIAqvqfe/Qi/zXl2StxCA4piiBC2uuVAuAOC6u+TfMafsAAAACXNzaDp2dWx0cg==
sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJ1OrjNP1ysix4konD3sk7Gd+hdt+I+5sUc0SJNRQksjAAAACXNzaDp2dWx0cg==
EOF

chown -R httpd:httpd /var/home/httpd/.ssh
chmod 0700 /var/home/httpd/.ssh
chmod 0600 /var/home/httpd/.ssh/authorized_keys


# ----------------------------
# Filesystem setup
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

mkdir -p /var/lib/postgres/experiments
chown -R experiments:experiments /var/lib/postgres
chmod 0700 /var/lib/postgres
chmod 0700 /var/lib/postgres/experiments

mkdir -p /var/log/caddy
chown -R caddy:caddy /var/log/caddy
chmod 0750 /var/log/caddy


# ----------------------------
# Runtime setup (containers + systemd)
# ----------------------------
ujust set-container-userns on

loginctl enable-linger httpd
loginctl enable-linger experiments
su - httpd -c "systemctl --user daemon-reload"
su - experiments -c "systemctl --user daemon-reload"

su - httpd -c "systemctl --user enable webdav.service"
su - experiments -c "systemctl --user enable postgres.service"

su - httpd -c "systemctl --user start webdav.service"
su - experiments -c "systemctl --user start postgres.service"

su - httpd -c "systemctl --user enable podman-auto-update.timer"
su - experiments -c "systemctl --user enable podman-auto-update.timer"


# ----------------------------
# Post-install Secureblue setup
# ----------------------------
ujust toggle-mac-randomization
ujust toggle-bash-environment-lockdown
ujust setup-usbguard
ujust enroll-secureblue-secure-boot-key
ujust set-kargs-hardening
ujust bios
ujust setup-luks-tpm-unlock

ujust audit-secureblue | tee /var/log/secureblue-audit.log
chown root:httpd /var/log/secureblue-audit.log
chmod 0640 /var/log/secureblue-audit.log
