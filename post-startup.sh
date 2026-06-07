#!/usr/bin/env bash
set -euo pipefail

# Runs as postgres user. Hash file written by post-startup-root.service.

if [ ! -d /var/lib/pgsql/data/base ]; then
    initdb -D /var/lib/pgsql/data
fi

cp /usr/share/postgres/*.conf /var/lib/pgsql/data/
chmod 0600 /var/lib/pgsql/data/*.conf

if [ -f /run/post-startup/hash ]; then
    /opt/scripts/bootstrap.sh
fi
