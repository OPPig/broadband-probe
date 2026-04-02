#!/usr/bin/env bash

run_check_dns() {
    [[ -n "${DNS_TARGETS:-}" ]] || return 0

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue

        local dns_server dns_name item_id label
        IFS='|' read -r dns_server dns_name item_id label <<< "${item}"

        log "running dns: server=${dns_server}, name=${dns_name}, id=${item_id}, label=${label}"

        local dns_result dns_time_raw dns_time_ms status

        dns_result="$(dig @"$dns_server" "$dns_name" +tries=1 +timeout=2 +short 2>/dev/null || true)"
        dns_time_raw="$( { /usr/bin/time -f '%e' dig @"$dns_server" "$dns_name" +tries=1 +timeout=2 +short >/dev/null; } 2>&1 || true )"

        dns_time_ms="0"
        if [[ "$dns_time_raw" =~ ^[0-9.]+$ ]]; then
            dns_time_ms="$(awk "BEGIN {printf \"%.0f\", $dns_time_raw*1000}")"
        fi

        if [[ -n "$dns_result" ]]; then
            status="1"
        else
            status="0"
        fi

        print_metric "dns.time[${item_id}]" "$dns_time_ms"
        print_metric "dns.status[${item_id}]" "$status"
    done < <(split_csv "${DNS_TARGETS}")
}
