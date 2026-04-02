#!/usr/bin/env bash

run_check_mtr() {
    [[ -n "${MTR_TARGETS:-}" ]] || return 0
    local mtr_count="${MTR_COUNT:-20}"

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue

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
    done < <(split_csv "${MTR_TARGETS}")
}
