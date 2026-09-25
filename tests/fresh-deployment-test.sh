#!/bin/bash

# VERSION=2026.9.24.3

set -euo pipefail

REPOSITORY="${RF_INSTALL_REPOSITORY:-Ne0n09/cloudflared-remotefalcon}"
MODE="both"
SOURCE_ENV=""
WORK_ROOT="${HOME}/rf-fresh-deployment-tests"
VERSION="latest"
UPDATE_FROM="v2026.9.18.3"
REPLACE_RUNNING=false
KEEP=false

SERVICES=(external-api ui plugins-api viewer control-panel cloudflared nginx mongo versitygw)
APP_SERVICES=(plugins-api control-panel viewer ui external-api)

usage() {
  cat <<EOF
Usage: $0 --source-env FILE [options]

Runs repeatable release and fresh deployment tests on a dedicated Linux host.

Options:
  --source-env FILE       Existing private .env whose values should be reused
  --mode MODE             update, local, remote, or both (default: both)
  --work-root DIR         Test directories and data (default: $WORK_ROOT)
  --version TAG           Release to install, or latest (default: latest)
  --update-from TAG       Older release used by the updater test
  --replace-running       Stop fixed-name Remote Falcon test containers
  --keep                  Keep the final deployment and test data
  -h, --help              Show this help

The remote mode requires valid GITHUB_PAT and REPO values in the source .env.
Secrets are copied into private test files and are not accepted as arguments.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-env) SOURCE_ENV="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --work-root) WORK_ROOT="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --update-from) UPDATE_FROM="${2:-}"; shift 2 ;;
    --replace-running) REPLACE_RUNNING=true; shift ;;
    --keep) KEEP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in
  update|local|remote|both) ;;
  *) echo "Invalid mode: $MODE" >&2; exit 2 ;;
esac

[[ -n "$SOURCE_ENV" && -f "$SOURCE_ENV" ]] || {
  echo "--source-env must name an existing .env file." >&2
  exit 2
}

for command in curl docker sha256sum awk sed grep mktemp install tee; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Docker is not available to the current user." >&2; exit 1; }

SOURCE_ENV="$(cd "$(dirname "$SOURCE_ENV")" && pwd)/$(basename "$SOURCE_ENV")"
SOURCE_RF_DIR="$(dirname "$SOURCE_ENV")"
WORK_ROOT="$(mkdir -p "$WORK_ROOT" && cd "$WORK_ROOT" && pwd)"
RESULTS_DIR="$WORK_ROOT/results"
mkdir -p "$RESULTS_DIR"
chmod 700 "$WORK_ROOT" "$RESULTS_DIR"

case "$WORK_ROOT" in
  /|/home|/tmp|/var|/usr|/etc|/opt|"$HOME")
    echo "Unsafe --work-root: $WORK_ROOT" >&2
    exit 2
    ;;
esac

read_env() {
  local key="$1" file="${2:-$SOURCE_ENV}"
  awk -v wanted="$key" '
    $0 !~ /^[[:space:]]*#/ && index($0, "=") {
      key=substr($0, 1, index($0, "=")-1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key == wanted) { print substr($0, index($0, "=")+1); exit }
    }
  ' "$file"
}

set_env() {
  local file="$1" key="$2" value="$3" temporary
  temporary=$(mktemp "${file}.XXXXXX")
  awk -v wanted="$key" -v replacement="$value" '
    BEGIN { found=0 }
    $0 !~ /^[[:space:]]*#/ && index($0, "=") {
      current=substr($0, 1, index($0, "=")-1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
      if (current == wanted) { print wanted "=" replacement; found=1; next }
    }
    { print }
    END { if (!found) print wanted "=" replacement }
  ' "$file" > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$file"
}

install_release() {
  local target="$1" version="$2" installer
  mkdir -p "$target"
  installer=$(mktemp)
  curl -fsSL --retry 3 -o "$installer" \
    "https://raw.githubusercontent.com/${REPOSITORY}/main/install.sh"
  bash "$installer" --target "$target" --version "$version" --no-configure
  rm -f "$installer"
}

copy_private_configuration() {
  local target="$1" env_file="$target/remotefalcon/.env" item source_path
  install -m 600 "$SOURCE_ENV" "$env_file"

  for item in NGINX_CERT NGINX_KEY; do
    source_path=$(read_env "$item")
    source_path="${source_path#./}"
    if [[ -n "$source_path" && -f "$SOURCE_RF_DIR/$source_path" ]]; then
      install -m 600 "$SOURCE_RF_DIR/$source_path" "$target/remotefalcon/$(basename "$source_path")"
    fi
  done
}

stop_running_services() {
  local running=false service
  for service in "${SERVICES[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$service"; then
      running=true
      break
    fi
  done

  if [[ "$running" != true ]]; then
    return
  fi
  if [[ "$REPLACE_RUNNING" != true ]]; then
    echo "Remote Falcon containers already exist. Rerun with --replace-running on a dedicated test host." >&2
    exit 2
  fi
  docker rm -f "${SERVICES[@]}" >/dev/null 2>&1 || true
}

remove_local_app_images() {
  local service reference
  for service in "${APP_SERVICES[@]}"; do
    while IFS= read -r reference; do
      [[ -n "$reference" && "${reference%%:*}" == "$service" ]] || continue
      docker image rm "$reference" >/dev/null
    done < <(docker image ls "$service" --format '{{.Repository}}:{{.Tag}}')
  done
}

cleanup_target() {
  local target="$1" mongo_path="$2" versity_path="$3"
  local path relative
  stop_running_services
  for path in "$target" "$mongo_path" "$versity_path"; do
    [[ -n "$path" && "$path" == "$WORK_ROOT"/* ]] || { echo "Refusing unsafe cleanup path: $path" >&2; exit 1; }
    [[ -e "$path" ]] || continue
    rm -rf -- "$path" 2>/dev/null || true
    if [[ -e "$path" ]]; then
      relative="${path#"$WORK_ROOT"/}"
      docker run --rm -v "$WORK_ROOT:/test-root" --entrypoint /bin/sh mongo:7.0.43 \
        -c 'rm -rf -- "/test-root/$1"' cleanup "$relative"
    fi
    [[ ! -e "$path" ]] || { echo "Failed to remove test path: $path" >&2; exit 1; }
  done
}

validate_update() {
  local target="$WORK_ROOT/update" mongo_image_before mongo_image_after
  cleanup_target "$target" "$WORK_ROOT/data/update-mongo" "$WORK_ROOT/data/update-versitygw"
  install_release "$target" "$UPDATE_FROM"
  copy_private_configuration "$target"
  mongo_image_before=$(awk '/^  mongo:/{found=1; next} found && /image:/{print $2; exit}' "$target/remotefalcon/compose.yaml")

  (cd "$target" && ./update_scripts.sh --version "$VERSION") | tee "$RESULTS_DIR/update.log"

  mongo_image_after=$(awk '/^  mongo:/{found=1; next} found && /image:/{print $2; exit}' "$target/remotefalcon/compose.yaml")
  [[ "$mongo_image_before" == "$mongo_image_after" ]] || { echo "Updater changed the pinned MongoDB image." >&2; return 1; }
  [[ ! -e "$target/remotefalcon/compose.yaml.new" ]] || { echo "Updater left an obsolete compose.yaml.new file." >&2; return 1; }
  docker compose --env-file "$target/remotefalcon/.env" -f "$target/remotefalcon/compose.yaml" config -q
  echo "PASS update $(cat "$target/VERSION")" | tee "$RESULTS_DIR/update.result"
}

prepare_deployment() {
  local build_mode="$1" target="$2" env_file="$target/remotefalcon/.env"
  local mongo_path="$WORK_ROOT/data/${build_mode}-mongo"
  local versity_path="$WORK_ROOT/data/${build_mode}-versitygw"
  cleanup_target "$target" "$mongo_path" "$versity_path"
  install_release "$target" "$VERSION"
  copy_private_configuration "$target"
  set_env "$env_file" MONGO_PATH "$mongo_path"
  set_env "$env_file" VERSITYGW_PATH "$versity_path"

  if [[ "$build_mode" == local ]]; then
    remove_local_app_images
    set_env "$env_file" REPO "username/repo"
    set_env "$env_file" GITHUB_PAT ""
    set_env "$env_file" DOCKERFILE "Dockerfile.dev"
  else
    [[ -n "$(read_env GITHUB_PAT "$env_file")" ]] || { echo "Remote mode requires GITHUB_PAT in the source .env." >&2; return 2; }
    [[ "$(read_env REPO "$env_file")" == */* ]] || { echo "Remote mode requires owner/repository in REPO." >&2; return 2; }
  fi
}

validate_deployment() {
  local build_mode="$1" target="$2" env_file="$target/remotefalcon/.env"
  local service image repo
  (cd "$target" && ./versitygw_init.sh && ./health_check.sh 0s) | tee "$RESULTS_DIR/${build_mode}-health.log"

  repo=$(read_env REPO "$env_file")
  for service in "${APP_SERVICES[@]}"; do
    image=$(docker inspect --format '{{.Config.Image}}' "$service")
    if [[ "$build_mode" == remote ]]; then
      [[ "$image" == "ghcr.io/${repo}/${service}:"* ]] || { echo "$service did not use a remote image: $image" >&2; return 1; }
    else
      [[ "$image" != ghcr.io/* ]] || { echo "$service unexpectedly used a remote image: $image" >&2; return 1; }
    fi
  done
  echo "PASS $build_mode $(cat "$target/VERSION")" | tee "$RESULTS_DIR/${build_mode}.result"
}

run_deployment() {
  local build_mode="$1" target="$WORK_ROOT/$1"
  prepare_deployment "$build_mode" "$target"
  (cd "$target" && ./configure-rf.sh -y --docker-mode manual) 2>&1 | tee "$RESULTS_DIR/${build_mode}-configure.log"
  validate_deployment "$build_mode" "$target"

  if [[ "$KEEP" != true ]]; then
    cleanup_target "$target" "$WORK_ROOT/data/${build_mode}-mongo" "$WORK_ROOT/data/${build_mode}-versitygw"
  fi
}

stop_running_services
validate_update

case "$MODE" in
  update) ;;
  local) run_deployment local ;;
  remote) run_deployment remote ;;
  both)
    run_deployment local
    run_deployment remote
    ;;
esac

echo "All requested tests passed. Results: $RESULTS_DIR"
