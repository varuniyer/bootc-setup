#!/usr/bin/env bash
set -euo pipefail

# boot-root.sh writes the hash file.
hash_file=/run/boot-postgresql/hash
if [ -f "$hash_file" ]; then
    /opt/scripts/bootstrap.sh < "$hash_file"
fi
