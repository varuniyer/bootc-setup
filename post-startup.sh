#!/usr/bin/env bash
set -euo pipefail

# ssh host keys (read via /etc/ssh symlinks)
mkdir -p /var/lib/sshd
for t in rsa ecdsa ed25519; do
    key="/var/lib/sshd/ssh_host_${t}_key"
    [ -s "$key" ] || ssh-keygen -q -t "$t" -f "$key" -C "" -N ""
done
chmod 0600 /var/lib/sshd/ssh_host_*_key
chmod 0644 /var/lib/sshd/ssh_host_*_key.pub
chcon -t sshd_key_t /var/lib/sshd/ssh_host_*

# webdav state
mkdir -p /var/lib/webdav/data /var/lib/webdav/lock
chown -R apache:apache /var/lib/webdav
chmod 0700 /var/lib/webdav /var/lib/webdav/data /var/lib/webdav/lock
if [ ! -e /var/lib/webdav/lock/lockdb ]; then
    touch /var/lib/webdav/lock/lockdb
    chown apache:apache /var/lib/webdav/lock/lockdb
    chmod 0600 /var/lib/webdav/lock/lockdb
fi

# caddy logs
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy
chmod 0750 /var/log/caddy

# postgres: initdb + bootstrap role/db on first boot, refresh configs every boot
need_bootstrap=
if [ ! -d /var/lib/pgsql/data/base ]; then
    postgresql-setup --initdb
    need_bootstrap=1
fi

cp /usr/share/postgres/*.conf /var/lib/pgsql/data/
chown postgres:postgres /var/lib/pgsql/data/*.conf
chmod 0600 /var/lib/pgsql/data/*.conf

if [ -n "$need_bootstrap" ]; then
    runuser -u postgres -- pg_ctl -D /var/lib/pgsql/data -l /tmp/pg-init.log -w start
    runuser -u postgres -- psql -d postgres -v ON_ERROR_STOP=1 -f /usr/share/postgres/bootstrap.sql
    runuser -u postgres -- pg_ctl -D /var/lib/pgsql/data -w stop
fi
