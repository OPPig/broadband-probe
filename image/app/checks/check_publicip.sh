#!/usr/bin/env bash

run_check_publicip() {
    local url_csv="${PUBLIC_IP_URLS:-${PUBLIC_IP_URL:-}}"
    [[ -n "$url_csv" ]] || return 0

    local state_dir="/tmp/probe-state"
    local idx_file="${state_dir}/publicip_url_idx"
    mkdir -p "$state_dir"

    local -a urls=()
    local raw_url
    while IFS= read -r raw_url; do
        raw_url="$(echo "$raw_url" | xargs)"
        [[ -n "$raw_url" ]] && urls+=("$raw_url")
    done < <(split_csv "$url_csv")

    local url_count="${#urls[@]}"
    (( url_count > 0 )) || return 0

    local start_idx=0
    if [[ -f "$idx_file" ]]; then
        start_idx="$(cat "$idx_file" 2>/dev/null || echo 0)"
        [[ "$start_idx" =~ ^[0-9]+$ ]] || start_idx=0
    fi
    start_idx=$((start_idx % url_count))
    echo $(((start_idx + 1) % url_count)) > "$idx_file"

    local ip="" selected_url="" try_url try_idx
    local i
    for ((i = 0; i < url_count; i++)); do
        try_idx=$(((start_idx + i) % url_count))
        try_url="${urls[$try_idx]}"

        log "running public ip check: url=${try_url} (try $((i + 1))/${url_count})"

        ip="$(curl -s --connect-timeout 3 --max-time 8 "${try_url}" || true)"
        ip="$(echo "$ip" | tr -d '\r' | tr -d '\n')"

        if [[ -n "$ip" ]]; then
            selected_url="$try_url"
            break
        fi
    done

    if [[ -n "$ip" ]]; then
        log "public ip resolved by ${selected_url}: ${ip}"
        print_metric "net.public.ip" "$ip"
        print_metric "net.public.ip.status" "1"
    else
        log "public ip check got empty response from all urls: ${url_csv}, skip net.public.ip value"
        print_metric "net.public.ip.status" "0"
    fi
}
