#!/usr/bin/env bash
set -euo pipefail

curl -sSf -H "Metadata-Flavor: Google" \
    "http://169.254.169.254/computeMetadata/v1/instance/attributes/$1"
