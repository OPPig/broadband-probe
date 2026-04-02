#!/usr/bin/env bash

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

split_csv() {
    local input="$1"
    echo "$input" | tr ',' '\n'
}

print_metric() {
    local key="$1"
    local value="$2"
    echo "${key}=${value}"
}

append_metric_file() {
    local key="$1"
    local value="$2"
    local file="$3"
    printf '%s %s %s\n' "$ZBX_HOST" "$key" "$value" >> "$file"
}

send_metric_file() {
    local file="$1"
    log "sending metrics to ${ZBX_SERVER}:${ZBX_PORT}, host=${ZBX_HOST}"
    zabbix_sender -z "$ZBX_SERVER" -p "$ZBX_PORT" -i "$file"
}

load_targets() {
    if [[ -f "${TARGETS_FILE:-/config/probe.targets}" ]]; then
        # shellcheck disable=SC1090
        source "${TARGETS_FILE:-/config/probe.targets}"
    fi
}
