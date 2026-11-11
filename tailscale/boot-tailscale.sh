#!/usr/bin/env bash
set -euo pipefail

# The marker needs its own StateDirectory because this unit drops CAP_DAC_OVERRIDE
# and /var/lib/tailscale is 0700 to tailscaled's DynamicUser.
marker=$STATE_DIRECTORY/logged-in
if [ ! -f "$marker" ]; then
    # The OAuth client secret flows through a file (private /tmp) so it stays out of argv.
    secret_file=$(mktemp)
    { /opt/scripts/fetch_metadata.sh ts-oauth-secret; printf '%s' '?ephemeral=false&preauthorized=true'; } > "$secret_file"

    tailscale up --auth-key="file:$secret_file" --hostname=bootc-server --advertise-tags=tag:server \
        --accept-dns=false --accept-routes=false --ssh=false
    rm -f "$secret_file"
    touch "$marker"
fi

# serve --https needs the netmap's cert domains, which arrive with the node's IPs.
until tailscale ip -4 >/dev/null 2>&1; do sleep 1; done

# Serve config persists in tailscaled state, so every boot resets it to match this file.
tailscale serve reset
tailscale serve --bg --tcp 5432 tcp://127.0.0.1:5432
tailscale serve --bg --https 8080 http://127.0.0.1:8080
