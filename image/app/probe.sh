#!/usr/bin/env bash
set -euo pipefail

if [[ -f /config/probe.env ]]; then
    # shellcheck disable=SC1091
    source /config/probe.env
fi

source /app/common.sh
load_targets

TMP_OUT="$(mktemp)"
TMP_ZBX="$(mktemp)"
STATE_DIR="/tmp/probe-state"
DISCOVERY_STAMP_FILE="${STATE_DIR}/last_discovery_ts"
trap 'rm -f "$TMP_OUT" "$TMP_ZBX"' EXIT

mkdir -p "$STATE_DIR"

DISCOVERY_INTERVAL="${DISCOVERY_INTERVAL:-300}"

log "probe start"
log "enabled checks: ${CHECKS:-}"

should_send_discovery() {
    local now last diff
    now="$(date +%s)"

    if [[ ! -f "$DISCOVERY_STAMP_FILE" ]]; then
        return 0
    fi

    last="$(cat "$DISCOVERY_STAMP_FILE" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0

    diff=$((now - last))
    (( diff >= DISCOVERY_INTERVAL ))
}

mark_discovery_sent() {
    date +%s > "$DISCOVERY_STAMP_FILE"
}

build_mtr_discovery() {
    [[ -n "${MTR_TARGETS:-}" ]] || return 0

    local json first item item_id label
    json="["
    first=1

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        IFS='|' read -r _target item_id label <<< "${item}"

        if [[ $first -eq 0 ]]; then
            json+=","
        fi

        json+="{\"{#MTRID}\":\"${item_id}\",\"{#MTRLABEL}\":\"${label}\"}"
        first=0
    done < <(split_csv "${MTR_TARGETS}")

    json+="]"

    print_metric "mtr.discovery" "$json"
}

build_dns_discovery() {
    [[ -n "${DNS_TARGETS:-}" ]] || return 0

    local json first item item_id label
    json="["
    first=1

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        IFS='|' read -r _server _domain item_id label <<< "${item}"

        if [[ $first -eq 0 ]]; then
            json+=","
        fi

        json+="{\"{#DNSID}\":\"${item_id}\",\"{#DNSLABEL}\":\"${label}\"}"
        first=0
    done < <(split_csv "${DNS_TARGETS}")

    json+="]"

    print_metric "dns.discovery" "$json"
}

build_http_discovery() {
    [[ -n "${HTTP_TARGETS:-}" ]] || return 0

    local json first item item_id label
    json="["
    first=1

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        IFS='|' read -r _url item_id label <<< "${item}"

        if [[ $first -eq 0 ]]; then
            json+=","
        fi

        json+="{\"{#HTTPID}\":\"${item_id}\",\"{#HTTPLABEL}\":\"${label}\"}"
        first=0
    done < <(split_csv "${HTTP_TARGETS}")

    json+="]"

    print_metric "http.discovery" "$json"
}

build_tcp_discovery() {
    [[ -n "${TCP_TARGETS:-}" ]] || return 0

    local json first item item_id label
    json="["
    first=1

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        IFS='|' read -r _target item_id label <<< "${item}"

        if [[ $first -eq 0 ]]; then
            json+=","
        fi

        json+="{\"{#TCPID}\":\"${item_id}\",\"{#TCPLABEL}\":\"${label}\"}"
        first=0
    done < <(split_csv "${TCP_TARGETS}")

    json+="]"

    print_metric "tcp.discovery" "$json"
}

for check in ${CHECKS:-}; do
    case "$check" in
        mtr)
            source /app/checks/check_mtr.sh
            run_check_mtr
            ;;
        dns)
            source /app/checks/check_dns.sh
            run_check_dns
            ;;
        http)
            source /app/checks/check_http.sh
            run_check_http
            ;;
        tcp)
            source /app/checks/check_tcp.sh
            run_check_tcp
            ;;
        publicip)
            source /app/checks/check_publicip.sh
            run_check_publicip
            ;;
        *)
            log "unknown check: $check"
            ;;
    esac
done | tee "$TMP_OUT"

print_metric "probe.alive" "1" >> "$TMP_OUT"

if should_send_discovery; then
    log "sending discovery payloads"

    build_mtr_discovery | tee -a "$TMP_OUT"
    build_dns_discovery | tee -a "$TMP_OUT"
    build_http_discovery | tee -a "$TMP_OUT"
    build_tcp_discovery | tee -a "$TMP_OUT"

    mark_discovery_sent
else
    log "skip discovery this round"
fi

while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue

    if [[ "$key" =~ ^[a-zA-Z0-9._-]+(\[[^]]+\])?$ ]]; then
        append_metric_file "$key" "$value" "$TMP_ZBX"
    fi
done < "$TMP_OUT"

log "prepared metric lines: $(wc -l < "$TMP_ZBX")"
send_metric_file "$TMP_ZBX"

log "probe done"
