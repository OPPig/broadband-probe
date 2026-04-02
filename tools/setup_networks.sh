#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV="$BASE_DIR/inventory/networks.csv"

log() { echo "[NET] $*"; }

tail -n +2 "$CSV" | while IFS=',' read -r name vlan parent subnet gw; do
  [[ -z "$name" ]] && continue

  iface="${parent}.${vlan}"

  if ip link show "$iface" >/dev/null 2>&1; then
    log "$iface already exists"
  else
    log "creating vlan iface $iface"
    ip link add link "$parent" name "$iface" type vlan id "$vlan"
    ip link set "$iface" up
  fi

  if docker network inspect "$name" >/dev/null 2>&1; then
    log "docker network $name already exists"
  else
    log "creating docker macvlan $name"
    docker network create -d macvlan \
      --subnet="$subnet" \
      --gateway="$gw" \
      -o parent="$iface" \
      "$name"
  fi
done

log "all networks ready"