#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
INST="$BASE/instances"
GEN="$BASE/generated/docker-compose.yml"
IMAGE_DIR="$BASE/image"
GLOBAL_CFG="$BASE/config/global.yaml"

log() { echo -e "\033[1;32m[DEPLOY]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

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

build_image_if_needed() {
  local image_name
  image_name="$(resolve_image_name)"

  if [[ "${SKIP_IMAGE_BUILD:-0}" == "1" ]]; then
    warn "skip image build (SKIP_IMAGE_BUILD=1), expected image: $image_name"
    return 0
  fi

  log "step 0: build probe image ($image_name)"
  docker build \
    --build-arg PROBE_UID="${PROBE_UID:-$(id -u)}" \
    --build-arg PROBE_GID="${PROBE_GID:-$(id -g)}" \
    -t "$image_name" \
    "$IMAGE_DIR" || die "docker build failed for image: $image_name"
}

build_image_if_needed

log "step 1: setup networks"
"$BASE/tools/setup_networks.sh"

log "step 2: generate configs"
python3 "$BASE/tools/generate_configs.py"

log "step 3: prune instances (folder sync)"
mapfile -t EXPECTED < <(tail -n +2 "$BASE/inventory/probes.csv" | cut -d',' -f1)

if [[ -d "$INST" ]]; then
  for dir in "$INST"/*; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"

    if ! printf '%s\n' "${EXPECTED[@]}" | grep -qx "$name"; then
      warn "remove stale instance dir: $name"
      rm -rf "$dir"
    fi
  done
fi

log "step 4: sync containers (compose)"
docker compose -f "$GEN" up -d --remove-orphans

log "done 🚀"
