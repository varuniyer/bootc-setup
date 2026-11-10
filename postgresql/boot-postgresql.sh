#!/usr/bin/env bash
set -euo pipefail

# Runs as postgres user. Hash file written by boot-root.service.

if [ -f /run/boot-postgresql/hash ]; then
    /opt/scripts/bootstrap.sh
fi

cp /usr/share/boot-postgresql/*.conf "$PGDATA"/
