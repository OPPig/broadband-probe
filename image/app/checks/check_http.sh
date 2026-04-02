#!/usr/bin/env bash

run_check_http_item() {
    local item="$1"
    local url item_id label
    IFS='|' read -r url item_id label <<< "${item}"

    log "running http: url=${url}, id=${item_id}, label=${label}"

    local http_time http_code http_time_ms status

    http_time="$(curl -o /dev/null -s -w '%{time_total}' --connect-timeout 3 --max-time 8 "$url" || true)"
    http_code="$(curl -o /dev/null -s -w '%{http_code}' --connect-timeout 3 --max-time 8 "$url" || true)"

    http_time_ms="0"
    if [[ "$http_time" =~ ^[0-9.]+$ ]]; then
        http_time_ms="$(awk "BEGIN {printf \"%.0f\", $http_time*1000}")"
    fi

    if [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
        status="1"
    else
        status="0"
    fi

    print_metric "http.time[${item_id}]" "$http_time_ms"
    print_metric "http.status[${item_id}]" "$status"
    print_metric "http.code[${item_id}]" "$http_code"
}

run_check_http() {
    [[ -n "${HTTP_TARGETS:-}" ]] || return 0

    local concurrency="${HTTP_CONCURRENCY:-${PROBE_CONCURRENCY:-4}}"
    log "http check concurrency=${concurrency}"

    run_items_in_parallel "${HTTP_TARGETS}" run_check_http_item "$concurrency"
}
