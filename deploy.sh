#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
INST="$BASE/instances"
GEN="$BASE/generated/docker-compose.yml"

log() { echo -e "\033[1;32m[DEPLOY]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

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