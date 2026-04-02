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

run_items_in_parallel() {
    local csv_input="$1"
    local worker_fn="$2"
    local max_parallel="$3"

    if ! [[ "$max_parallel" =~ ^[1-9][0-9]*$ ]]; then
        max_parallel=1
    fi

    local -a pids=()
    local item pid next_pids

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue

        "$worker_fn" "$item" &
        pids+=("$!")

        while (( ${#pids[@]} >= max_parallel )); do
            next_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    next_pids+=("$pid")
                else
                    wait "$pid" || true
                fi
            done
            pids=("${next_pids[@]}")

            (( ${#pids[@]} >= max_parallel )) && sleep 0.05
        done
    done < <(split_csv "$csv_input")

    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done
}
