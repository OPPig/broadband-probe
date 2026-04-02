#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
INV_DIR="$BASE/inventory"
INST_DIR="$BASE/instances"
GEN_COMPOSE="$BASE/generated/docker-compose.yml"
GLOBAL_CFG="$BASE/config/global.yaml"

PURGE_FILES=0
REMOVE_IMAGE=0

log() { echo -e "\033[1;34m[UNINSTALL]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [options]

Options:
  --purge-files   Remove generated files/directories (generated/, instances/)
  --remove-image  Remove probe image configured in config/global.yaml
  -h, --help      Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-files) PURGE_FILES=1 ;;
    --remove-image) REMOVE_IMAGE=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      warn "unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

get_csv_first_col() {
  local csv_file="$1"
  [[ -f "$csv_file" ]] || return 0
  awk -F',' 'NR>1 && $1!="" {print $1}' "$csv_file"
}

resolve_image_name() {
  python3 - "$GLOBAL_CFG" <<'PY'
import sys
from pathlib import Path
import yaml

cfg_path = Path(sys.argv[1])
if not cfg_path.exists():
    print("broadband-probe:latest")
    sys.exit(0)

with cfg_path.open("r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

image = str((cfg.get("docker") or {}).get("image") or "").strip()
print(image or "broadband-probe:latest")
PY
}

log "step 1: stop compose stack"
if [[ -f "$GEN_COMPOSE" ]]; then
  docker compose -f "$GEN_COMPOSE" down --remove-orphans || warn "compose down failed"
else
  warn "compose file not found: $GEN_COMPOSE, skip compose down"
fi

log "step 2: remove probe containers"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    docker rm -f "$name" >/dev/null || warn "failed to remove container: $name"
    log "removed container: $name"
  fi
done < <(get_csv_first_col "$INV_DIR/probes.csv")

log "step 3: remove docker networks and vlan interfaces"
if [[ -f "$INV_DIR/networks.csv" ]]; then
  while IFS=',' read -r network_name vlan parent_if _subnet _gateway; do
    [[ "$network_name" == "network_name" ]] && continue
    [[ -n "${network_name:-}" ]] || continue
    iface="${parent_if}.${vlan}"

    if docker network inspect "$network_name" >/dev/null 2>&1; then
      docker network rm "$network_name" >/dev/null || warn "failed to remove network: $network_name"
      log "removed network: $network_name"
    fi

    if ip link show "$iface" >/dev/null 2>&1; then
      ip link delete "$iface" >/dev/null || warn "failed to delete iface: $iface"
      log "deleted iface: $iface"
    fi
  done < "$INV_DIR/networks.csv"
else
  warn "networks.csv not found, skip network/interface cleanup"
fi

if [[ "$PURGE_FILES" == "1" ]]; then
  log "step 4: purge generated files"
  rm -rf "$INST_DIR" "$BASE/generated"
fi

if [[ "$REMOVE_IMAGE" == "1" ]]; then
  log "step 5: remove probe image"
  IMAGE_NAME="$(resolve_image_name)"
  docker image rm "$IMAGE_NAME" >/dev/null || warn "failed to remove image: $IMAGE_NAME"
fi

log "uninstall done"
