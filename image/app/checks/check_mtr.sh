#!/usr/bin/env bash

run_check_mtr_item() {
    local item="$1"
    local mtr_count="$2"
    local target item_id label
    IFS='|' read -r target item_id label <<< "${item}"

    log "running mtr: target=${target}, id=${item_id}, label=${label}"

    local tmpfile
    tmpfile="$(mktemp)"

    mtr -r -n -c "$mtr_count" "$target" >"$tmpfile" 2>/dev/null || true

    local last_line loss avg jitter
    last_line="$(tail -n 1 "$tmpfile" 2>/dev/null || true)"
    rm -f "$tmpfile"

    loss="100"
    avg="0"
    jitter="0"

    if [[ -n "$last_line" ]]; then
        loss="$(echo "$last_line" | awk '{print $3}' | tr -d '%')"
        avg="$(echo "$last_line" | awk '{print $6}')"
        jitter="$(echo "$last_line" | awk '{print $9}')"

        [[ "$loss" =~ ^[0-9.]+$ ]] || loss="100"
        [[ "$avg" =~ ^[0-9.]+$ ]] || avg="0"
        [[ "$jitter" =~ ^[0-9.]+$ ]] || jitter="0"
    fi

    print_metric "net.loss[${item_id}]" "$loss"
    print_metric "net.latency[${item_id}]" "$avg"
    print_metric "net.jitter[${item_id}]" "$jitter"
}

run_check_mtr_item_wrapper() {
    run_check_mtr_item "$1" "${MTR_COUNT:-20}"
}

run_check_mtr() {
    [[ -n "${MTR_TARGETS:-}" ]] || return 0

    local concurrency="${MTR_CONCURRENCY:-${PROBE_CONCURRENCY:-2}}"
    log "mtr check concurrency=${concurrency}"

    run_items_in_parallel "${MTR_TARGETS}" run_check_mtr_item_wrapper "$concurrency"
}
