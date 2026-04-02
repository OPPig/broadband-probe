#!/usr/bin/env bash
set -euo pipefail

if [[ -f /config/probe.env ]]; then
    # shellcheck disable=SC1091
    source /config/probe.env
fi

while true; do
    bash /app/probe.sh
    sleep "${INTERVAL:-60}"
done
