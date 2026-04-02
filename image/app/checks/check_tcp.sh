#!/usr/bin/env bash

run_check_tcp_item() {
    local item="$1"
    local hostport item_id label host port
    IFS='|' read -r hostport item_id label <<< "${item}"
    host="${hostport%%:*}"
    port="${hostport##*:}"

    log "running tcp: target=${host}:${port}, id=${item_id}, label=${label}"

    local start end elapsed_ms status

    start="${EPOCHREALTIME}"

    if nc -zw3 "$host" "$port" >/dev/null 2>&1; then
        end="${EPOCHREALTIME}"
        elapsed_ms="$(awk -v s="$start" -v e="$end" 'BEGIN {printf "%.0f", (e-s)*1000}')"
        status="1"
    else
        elapsed_ms="0"
        status="0"
    fi

    print_metric "tcp.time[${item_id}]" "$elapsed_ms"
    print_metric "tcp.status[${item_id}]" "$status"
}

run_check_tcp() {
    [[ -n "${TCP_TARGETS:-}" ]] || return 0

    local concurrency="${TCP_CONCURRENCY:-${PROBE_CONCURRENCY:-4}}"
    log "tcp check concurrency=${concurrency}"

    run_items_in_parallel "${TCP_TARGETS}" run_check_tcp_item "$concurrency"
}
