#!/usr/bin/env bash
set -euo pipefail

curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
