#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
INST="$BASE/instances"
GEN="$BASE/generated/docker-compose.yml"
IMAGE_DIR="$BASE/image"
GLOBAL_CFG="$BASE/config/global.yaml"
CACHE_DIR="$BASE/.cache"

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

image_hash_file() {
  local image_name="$1"
  local safe_name
  safe_name="$(echo "$image_name" | sed 's#[^a-zA-Z0-9_.-]#_#g')"
  echo "$CACHE_DIR/${safe_name}.image.sha256"
}

compute_image_context_hash() {
  (
    cd "$IMAGE_DIR"
    find . -type f -print0 \
      | sort -z \
      | xargs -0 sha256sum \
      | sha256sum \
      | awk '{print $1}'
  )
}

image_exists_locally() {
  local image_name="$1"
  docker image inspect "$image_name" >/dev/null 2>&1
}

should_rebuild_image() {
  local image_name="$1"
  local hash_file="$2"
  local current_hash="$3"
  local last_hash=""
  local recommended_action="skip"
  local reason=""
  local choice

  if [[ -f "$hash_file" ]]; then
    last_hash="$(cat "$hash_file")"
  fi

  if ! image_exists_locally "$image_name"; then
    recommended_action="rebuild"
    reason="本地不存在镜像: $image_name（首次部署或镜像被清理）"
  elif [[ -z "$last_hash" || "$current_hash" != "$last_hash" ]]; then
    recommended_action="rebuild"
    reason="image/ 构建上下文发生变化（例如 Dockerfile 或 image/app 脚本变更）"
  else
    recommended_action="skip"
    reason="image/ 内容未变化（仅 inventory/config 等运行配置变化通常不需要重建）"
  fi

  if [[ -t 0 ]]; then
    echo
    log "image rebuild hint:"
    echo "  - 推荐动作: $recommended_action"
    echo "  - 原因: $reason"
    echo "  - 需要重建镜像的典型场景:"
    echo "      1) image/Dockerfile 变更（基础镜像、安装包、用户等）"
    echo "      2) image/app 下脚本变更"
    echo "      3) 本地镜像不存在或被删除"
    echo "  - 通常可跳过重建的场景:"
    echo "      1) 仅 inventory/、config/、generated/ 变化"
    echo "      2) 仅实例数量或目标配置变化"
    read -r -p "是否重建镜像? [y/N]: " choice
    case "${choice:-N}" in
      y|Y|yes|YES) return 0 ;;
      *) return 1 ;;
    esac
  fi

  if [[ "$recommended_action" == "rebuild" ]]; then
    warn "non-interactive mode: auto rebuild ($reason)"
    return 0
  fi

  warn "non-interactive mode: auto skip image rebuild ($reason)"
  return 1
}

build_image_if_needed() {
  local image_name
  local hash_file
  local current_hash
  image_name="$(resolve_image_name)"
  hash_file="$(image_hash_file "$image_name")"
  current_hash="$(compute_image_context_hash)"
  mkdir -p "$CACHE_DIR"

  if [[ "${SKIP_IMAGE_BUILD:-0}" == "1" ]]; then
    warn "skip image build (SKIP_IMAGE_BUILD=1), expected image: $image_name"
    return 0
  fi

  if [[ "${FORCE_IMAGE_BUILD:-0}" == "1" ]]; then
    warn "force image build (FORCE_IMAGE_BUILD=1)"
  elif ! should_rebuild_image "$image_name" "$hash_file" "$current_hash"; then
    warn "skip image build by decision, expected image: $image_name"
    return 0
  fi

  log "step 0: build probe image ($image_name)"
  docker build \
    --build-arg PROBE_UID="${PROBE_UID:-$(id -u)}" \
    --build-arg PROBE_GID="${PROBE_GID:-$(id -g)}" \
    -t "$image_name" \
    "$IMAGE_DIR" || die "docker build failed for image: $image_name"
  echo "$current_hash" > "$hash_file"
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
