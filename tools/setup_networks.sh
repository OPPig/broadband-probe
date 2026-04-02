#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV="$BASE_DIR/inventory/networks.csv"

log() { echo "[NET] $*"; }
die() { echo "[NET][ERROR] $*" >&2; exit 1; }

[[ -f "$CSV" ]] || die "networks csv not found: $CSV"

mapfile -t NETWORK_ROWS < <(
  python3 - "$CSV" <<'PY'
import csv
import ipaddress
import sys

path = sys.argv[1]
required = ["network_name", "vlan_id", "parent_if", "subnet", "gateway"]

with open(path, newline="", encoding="utf-8-sig") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        print("[NET][ERROR] networks.csv is empty", file=sys.stderr)
        sys.exit(1)
    if reader.fieldnames != required:
        print(
            "[NET][ERROR] networks.csv header must be exactly: "
            "network_name,vlan_id,parent_if,subnet,gateway",
            file=sys.stderr,
        )
        sys.exit(1)

    for idx, row in enumerate(reader, start=2):
        name = (row.get("network_name") or "").strip()
        vlan = (row.get("vlan_id") or "").strip()
        parent = (row.get("parent_if") or "").strip()
        subnet_raw = (row.get("subnet") or "").strip()
        gw_raw = (row.get("gateway") or "").strip()

        if not name:
            continue
        if not vlan.isdigit():
            print(f"[NET][ERROR] networks.csv line {idx}: vlan_id must be numeric", file=sys.stderr)
            sys.exit(1)

        vlan_id = int(vlan)
        if vlan_id < 1 or vlan_id > 4094:
            print(
                f"[NET][ERROR] networks.csv line {idx}: vlan_id out of range (1-4094): {vlan_id}",
                file=sys.stderr,
            )
            sys.exit(1)

        if not parent:
            print(f"[NET][ERROR] networks.csv line {idx}: parent_if is empty", file=sys.stderr)
            sys.exit(1)

        try:
            subnet = ipaddress.ip_network(subnet_raw, strict=True)
        except ValueError as e:
            print(f"[NET][ERROR] networks.csv line {idx}: invalid subnet '{subnet_raw}': {e}", file=sys.stderr)
            sys.exit(1)

        try:
            gateway = ipaddress.ip_address(gw_raw)
        except ValueError as e:
            print(f"[NET][ERROR] networks.csv line {idx}: invalid gateway '{gw_raw}': {e}", file=sys.stderr)
            sys.exit(1)

        if gateway not in subnet:
            print(
                f"[NET][ERROR] networks.csv line {idx}: gateway {gateway} not in subnet {subnet}",
                file=sys.stderr,
            )
            sys.exit(1)

        print(f"{name}\t{vlan_id}\t{parent}\t{subnet}\t{gateway}")
PY
)

for row in "${NETWORK_ROWS[@]}"; do
  IFS=$'\t' read -r name vlan parent subnet gw <<< "$row"

  iface="${parent}.${vlan}"

  if ip link show "$iface" >/dev/null 2>&1; then
    log "$iface already exists"
  else
    log "creating vlan iface $iface"
    ip link add link "$parent" name "$iface" type vlan id "$vlan" \
      || die "failed to create vlan iface $iface"
    ip link set "$iface" up || die "failed to bring up iface $iface"
  fi

  if docker network inspect "$name" >/dev/null 2>&1; then
    log "docker network $name already exists"
  else
    log "creating docker macvlan $name"
    docker network create -d macvlan \
      --subnet="$subnet" \
      --gateway="$gw" \
      -o parent="$iface" \
      "$name" >/dev/null || die "failed to create docker network $name"
  fi
done

log "all networks ready"
