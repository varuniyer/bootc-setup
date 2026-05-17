#!/usr/bin/env bash
set -euo pipefail

podman image trust set -t accept docker.io/library/httpd
podman image trust set -t accept docker.io/library/postgres
podman image trust set -t sigstoreSigned \
    --pubkeysfile /etc/containers/keys/cosign.pub \
    ghcr.io/varuniyer/bootc-setup

tmp=$(mktemp)
jq --arg key /etc/containers/keys/cosign.pub '
  .transports["containers-storage"][""] = [{
    "type": "sigstoreSigned",
    "keyPath": $key,
    "signedIdentity": { "type": "matchRepository" }
  }]
' /etc/containers/policy.json > "$tmp"
mv "$tmp" /etc/containers/policy.json

ujust set-container-userns on
ujust toggle-mac-randomization
ujust toggle-bash-environment-lockdown
ujust setup-usbguard
