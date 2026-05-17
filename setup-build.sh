#!/usr/bin/env bash
set -euo pipefail

ujust set-container-userns on
ujust toggle-mac-randomization
ujust toggle-bash-environment-lockdown
ujust setup-usbguard
