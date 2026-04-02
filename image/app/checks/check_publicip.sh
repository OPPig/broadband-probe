#!/usr/bin/env bash

run_check_publicip() {
    [[ -n "${PUBLIC_IP_URL:-}" ]] || return 0

    log "running public ip check: url=${PUBLIC_IP_URL}"

    local ip
    ip="$(curl -s --connect-timeout 3 --max-time 8 "${PUBLIC_IP_URL}" || true)"
    ip="$(echo "$ip" | tr -d '\r' | tr -d '\n')"

    if [[ -n "$ip" ]]; then
        print_metric "net.public.ip" "$ip"
        print_metric "net.public.ip.status" "1"
    else
        print_metric "net.public.ip" ""
        print_metric "net.public.ip.status" "0"
    fi
}
