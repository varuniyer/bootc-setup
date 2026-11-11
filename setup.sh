#!/usr/bin/env bash
set -euo pipefail

# Nothing logs into the VM.
dnf remove -y openssh-server openssh-clients
rm -rf /etc/ssh
# avahi serves mDNS. nfs-utils, gssproxy, and rpcbind serve NFS. kmscon draws a
# console on tty1. The image uses none of them.
dnf remove -y avahi avahi-libs nfs-utils gssproxy rpcbind kmscon
# systemd-getty-generator adds a login prompt on the kernel's serial console.
# Masking the template drops it, and the serial log stays readable.
systemctl mask serial-getty@.service

# COPY'd binaries need SELinux labels.
restorecon -R /usr/bin /usr/lib64

semodule -n -i /usr/share/selinux/packages/caddy_local.cil

groupadd -r caddy
useradd -r -g caddy -d /var/lib/caddy -s /usr/sbin/nologin caddy
# A pinned uid/gid keeps /var/lib/pgsql readable across image builds. 26 matches
# Fedora's PostgreSQL packaging.
groupadd -r -g 26 postgres
useradd -r -u 26 -g postgres -d /var/lib/pgsql -s /usr/sbin/nologin postgres

mkdir /etc/webdav /etc/pki/containers

# rpm-ostree's tmpfiles entry needs /usr/local/sbin, and /usr is read-only at boot.
mkdir /usr/local/sbin

# Rebuild initramfs so prepare-root.conf's [etc] transient takes effect.
# /root is a symlink to /var/roothome, which rpm-ostree's tmpfiles entry creates at boot.
# Materialize it for dracut-install, then remove it.
KVER=$(basename /usr/lib/modules/*)
mkdir /var/roothome
dracut --no-hostonly --force --kver "$KVER" /usr/lib/modules/"$KVER"/initramfs.img
rmdir /var/roothome

# The base image ships group-writable files that its own RPMs declare 0644,
# and a umask-002 checkout makes COPY'd files group-writable.
find /usr /etc /opt \( -type f -o -type d \) -perm /022 -exec chmod go-w {} +

chown root:caddy /etc/caddy/Caddyfile
chmod 0640 /etc/caddy/Caddyfile

# boot-root.service runs as Group=pghash, so the PostgreSQL hash it writes
# belongs to pghash, and postgres reads it as a member.
groupadd -r pghash
usermod -aG pghash postgres

# Every shipped unit links the shared sandbox.
for unit in boot-root boot-tailscale boot-postgresql tailscaled rclone-webdav caddy postgresql; do
    mkdir -p /usr/lib/systemd/system/$unit.service.d
    ln -s ../../sandbox.conf /usr/lib/systemd/system/$unit.service.d/sandbox.conf
done
for unit in boot-postgresql postgresql; do
    ln -s ../../run-as-postgres.conf /usr/lib/systemd/system/$unit.service.d/run-as-postgres.conf
done
for unit in boot-root boot-postgresql postgresql; do
    ln -s ../../pgdata.conf /usr/lib/systemd/system/$unit.service.d/pgdata.conf
done

systemctl enable nftables tailscaled boot-tailscale rclone-webdav caddy postgresql bootc-fetch-apply-updates.timer

bootc container lint
