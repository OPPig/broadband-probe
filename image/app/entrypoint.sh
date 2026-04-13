#!/usr/bin/env bash
set -euo pipefail

if [[ -f /config/probe.env ]]; then
    # shellcheck disable=SC1091
    source /config/probe.env
fi

while true; do
    if ! bash /app/probe.sh; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] probe run failed, continue next interval"
    fi
    sleep "${INTERVAL:-60}"
done
