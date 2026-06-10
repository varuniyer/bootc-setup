#!/usr/bin/env bash
set -euo pipefail

# First boot only. Marker lives in this unit's own StateDirectory because
# /var/lib/tailscale is 0700 under tailscaled's DynamicUser and this unit
# drops CAP_DAC_OVERRIDE.
marker=/var/lib/post-startup-tailscale/provisioned
[ -f "$marker" ] && exit 0

# Auth key flows through a file (private /tmp) so it stays out of argv.
key_file=$(mktemp)
{
    /opt/scripts/fetch_metadata.sh ts-authkey
    printf '%s' '?ephemeral=false&preauthorized=true'
} > "$key_file"

# --netfilter-mode=off keeps tailscaled away from the static nftables
# ruleset; it's a preference, so it persists in state across reboots.
tailscale up \
    --auth-key="file:$key_file" \
    --advertise-tags=tag:server \
    --netfilter-mode=off \
    --accept-dns=false \
    --accept-routes=false \
    --ssh=false
rm -f "$key_file"

# Serve config persists in tailscaled state, so this also runs once.
tailscale serve --bg --tcp 5432 tcp://127.0.0.1:5432
tailscale serve --bg --tcp 8080 tcp://127.0.0.1:8080

touch "$marker"
