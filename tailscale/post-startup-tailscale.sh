#!/usr/bin/env bash
set -euo pipefail

# First boot only. The marker needs its own StateDirectory because this unit
# drops CAP_DAC_OVERRIDE and /var/lib/tailscale is 0700 to tailscaled's DynamicUser.
marker=/var/lib/post-startup-tailscale/provisioned
[ -f "$marker" ] && exit 0

# Auth key flows through a file (private /tmp) so it stays out of argv.
key_file=$(mktemp)
{
    /opt/scripts/fetch_metadata.sh ts-authkey
    printf '%s' '?ephemeral=false&preauthorized=true'
} > "$key_file"

tailscale up \
    --auth-key="file:$key_file" \
    --advertise-tags=tag:server \
    --accept-dns=false \
    --accept-routes=false \
    --ssh=false
rm -f "$key_file"

# Serve config persists in tailscaled state, so this also runs once.
tailscale serve --bg --tcp 5432 tcp://127.0.0.1:5432
tailscale serve --bg --tcp 8080 tcp://127.0.0.1:8080

touch "$marker"
