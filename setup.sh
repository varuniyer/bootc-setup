#!/usr/bin/env bash
set -euo pipefail

# Nothing ever logs into the VM.
dnf remove -y openssh-server openssh-clients
rm -rf /etc/ssh
# avahi serves mDNS, nfs-utils, gssproxy, and rpcbind serve NFS, and kmscon
# draws a console on tty1. The image uses none of them.
dnf remove -y avahi avahi-libs nfs-utils gssproxy rpcbind kmscon
# systemd-getty-generator adds a login prompt on the kernel's serial console.
# Masking the template drops it, and the serial log stays readable.
systemctl mask serial-getty@.service

# COPY'd binaries need SELinux labels.
restorecon -R /usr/bin /usr/lib64

semodule -n -i /usr/share/selinux/packages/caddy_local.cil

# uid/gid 26 matches Fedora's PostgreSQL packaging so existing /var/lib/pgsql
# data stays readable.
groupadd -r caddy
useradd -r -g caddy -d /var/lib/caddy -s /usr/sbin/nologin caddy
groupadd -r -g 26 postgres
useradd -r -u 26 -g postgres -d /var/lib/pgsql -s /usr/sbin/nologin postgres

mkdir /etc/webdav /etc/pki/containers

# rpm-ostree's tmpfiles entry needs /usr/local/sbin, and /usr is read-only at boot.
mkdir /usr/local/sbin

# Rebuild initramfs so prepare-root.conf's [etc] transient takes effect.
# /root is a symlink to /var/roothome. Materialize it for dracut-install,
# then remove it so the image's /var stays empty.
KVER=$(basename /usr/lib/modules/*)
mkdir /var/roothome
dracut --no-hostonly --force --kver "$KVER" /usr/lib/modules/"$KVER"/initramfs.img
rmdir /var/roothome

# The base image ships group-writable files that its own RPMs declare 0644,
# and a umask-002 checkout makes COPY'd files group-writable.
find /usr /etc /opt \( -type f -o -type d \) -perm /022 -exec chmod go-w {} +

chown root:caddy /etc/caddy/Caddyfile
chmod 0640 /etc/caddy/Caddyfile

# boot-root.service runs as Group=creds, so the PostgreSQL hash it writes
# belongs to creds, and postgres reads it as a member.
groupadd -r creds
usermod -aG creds postgres

# Every shipped unit links the shared sandbox.
for unit in boot-root boot-tailscale boot-postgresql tailscaled rclone-webdav caddy postgresql; do
    mkdir /usr/lib/systemd/system/$unit.service.d
    ln -s ../../hardening.conf /usr/lib/systemd/system/$unit.service.d/hardening.conf
done
for unit in boot-postgresql postgresql; do
    ln -s ../../postgresql-service.conf /usr/lib/systemd/system/$unit.service.d/postgresql-service.conf
done

systemctl enable nftables tailscaled boot-tailscale rclone-webdav caddy postgresql bootc-fetch-apply-updates.timer

bootc container lint
