#!/bin/bash

# VERSION=2026.5.20.1

# Testing utility to undo RF installations and remove all generated files, containers, and images.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RF_DIR="$SCRIPT_DIR/remotefalcon"
BACKUP_DIR="$SCRIPT_DIR/remotefalcon-backups"
ENV_FILE="$RF_DIR/.env"
COMPOSE_FILE="$RF_DIR/compose.yaml"

DEFAULT_MONGO_PATH="/home/mongo-volume"
DEFAULT_VERSITYGW_PATH="/home/versitygw-volume"

MONGO_PATH="$DEFAULT_MONGO_PATH"
VERSITYGW_PATH="$DEFAULT_VERSITYGW_PATH"

NON_INTERACTIVE=false
DRY_RUN=false
REMOVE_SCRIPTS=true
STOP_CONTAINERS=true
REMOVE_DATA=true
REMOVE_CONFIG=true
REMOVE_IMAGES=true

SCRIPTS_TO_REMOVE=(
  "configure-rf.sh"
  "shared_functions.sh"
  "update_containers.sh"
  "health_check.sh"
  "versitygw_init.sh"
  "setup_cloudflare.sh"
  "run_workflow.sh"
  "sync_repo_secrets.sh"
)

SERVICES=(
  "external-api"
  "ui"
  "plugins-api"
  "viewer"
  "control-panel"
  "cloudflared"
  "nginx"
  "mongo"
  "versitygw"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
  cat <<EOF
Usage: ./cleanup-rf.sh [options]

Options:
  -y|--yes                 Run without prompts
  --dry-run                Show what would be removed, but do not remove it
  --keep-scripts           Keep downloaded helper scripts
  --keep-data              Keep MongoDB and Versity Gateway data directories
  --keep-config            Keep remotefalcon and remotefalcon-backups directories
  --keep-images            Keep Docker images to avoid re-downloading on next install
  --no-stop                Do not stop or remove Docker containers
  -h|--help                Show this help message

This removes the default generated install paths:
  $RF_DIR
  $BACKUP_DIR
  $MONGO_PATH
  $VERSITYGW_PATH
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      NON_INTERACTIVE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --keep-scripts)
      REMOVE_SCRIPTS=false
      shift
      ;;
    --keep-data)
      REMOVE_DATA=false
      shift
      ;;
    --keep-config)
      REMOVE_CONFIG=false
      shift
      ;;
    --keep-images)
      REMOVE_IMAGES=false
      shift
      ;;
    --no-stop)
      STOP_CONTAINERS=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}❌ Unknown option: $1${NC}" >&2
      usage
      exit 2
      ;;
  esac
done

load_env_paths() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]] && continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    case "$key" in
      MONGO_PATH)
        [[ -n "$value" ]] && MONGO_PATH="$value"
        ;;
      VERSITYGW_PATH)
        [[ -n "$value" ]] && VERSITYGW_PATH="$value"
        ;;
    esac
  done < "$ENV_FILE"
}

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${BLUE}DRY RUN:${NC} $*"
    return 0
  fi

  "$@"
}

confirm_cleanup() {
  if [[ "$NON_INTERACTIVE" == "true" || "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  echo
  echo -e "${YELLOW}⚠️ This will permanently remove the selected Remote Falcon install files and data directories.${NC}"
  echo -ne "${CYAN}Type CLEAN to continue: ${NC}"
  read -r confirmation

  if [[ "$confirmation" != "CLEAN" ]]; then
    echo -e "${YELLOW}⚠️ Cleanup cancelled.${NC}"
    exit 0
  fi
}

stop_docker_resources() {
  if [[ "$STOP_CONTAINERS" != "true" ]]; then
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️ Docker was not found. Skipping container cleanup.${NC}"
    return
  fi

  echo -e "${CYAN}🧹 Stopping Remote Falcon containers...${NC}"

  if [[ -f "$COMPOSE_FILE" ]]; then
    run_cmd sudo docker compose -f "$COMPOSE_FILE" down --remove-orphans
  fi

  for service in "${SERVICES[@]}"; do
    if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$service"; then
      echo -e "${BLUE}Removing container:${NC} $service"
      run_cmd sudo docker rm -f "$service"
    fi
  done
}

remove_path() {
  local path="$1"
  local label="$2"

  case "$path" in
    ""|"/"|"/home"|"/tmp"|"/var"|"/usr"|"/etc"|"/opt"|"$SCRIPT_DIR")
      echo -e "${RED}❌ Refusing to remove unsafe $label path: '$path'${NC}"
      return 1
      ;;
  esac

  if [[ "$path" == "$HOME" ]]; then
    echo -e "${RED}❌ Refusing to remove unsafe $label path: '$path'${NC}"
    return 1
  fi

  if [[ ! -e "$path" ]]; then
    echo -e "${YELLOW}⚠️ $label not found: $path${NC}"
    return 0
  fi

  echo -e "${BLUE}Removing $label:${NC} $path"
  run_cmd sudo rm -rf "$path"
}

remove_config_paths() {
  if [[ "$REMOVE_CONFIG" != "true" ]]; then
    return
  fi

  remove_path "$RF_DIR" "Remote Falcon config directory"
  remove_path "$BACKUP_DIR" "Remote Falcon backup directory"
}

remove_data_paths() {
  if [[ "$REMOVE_DATA" != "true" ]]; then
    return
  fi

  remove_path "$MONGO_PATH" "MongoDB data directory"
  remove_path "$VERSITYGW_PATH" "Versity Gateway data directory"
}

remove_script_paths() {
  if [[ "$REMOVE_SCRIPTS" != "true" ]]; then
    return
  fi

  for script in "${SCRIPTS_TO_REMOVE[@]}"; do
    remove_path "$SCRIPT_DIR/$script" "script"
  done
}

remove_container_images() {
  if [[ "$REMOVE_IMAGES" != "true" ]]; then
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️ Docker was not found. Skipping image cleanup.${NC}"
    return
  fi

  echo -e "${CYAN}🧹 Removing Remote Falcon Docker images...${NC}"

  for service in "${SERVICES[@]}"; do
    mapfile -t image_ids < <(
      sudo docker images \
        --format '{{.Repository}}:{{.Tag}} {{.ID}}' |
        grep -E "/${service}(:|$| )" |
        awk '{print $2}' |
        sort -u
    )

    if [[ ${#image_ids[@]} -gt 0 ]]; then
      echo -e "${BLUE}Removing images for service:${NC} $service"

      for image_id in "${image_ids[@]}"; do
        echo -e "  ${CYAN}→ Removing image ID:${NC} $image_id"
        run_cmd sudo docker rmi -f "$image_id"
      done
    fi
  done

  sudo docker image prune -a -f
  sudo docker builder prune -a -f
}

print_summary() {
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}Remote Falcon cleanup plan${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "Script directory:       ${YELLOW}$SCRIPT_DIR${NC}"
  echo -e "Stop containers:        ${YELLOW}$STOP_CONTAINERS${NC}"
  echo -e "Remove config/backups:  ${YELLOW}$REMOVE_CONFIG${NC}"
  echo -e "Remove images:          ${YELLOW}$REMOVE_IMAGES${NC}"
  echo -e "Remove data dirs:       ${YELLOW}$REMOVE_DATA${NC}"
  echo -e "Remove helper scripts:  ${YELLOW}$REMOVE_SCRIPTS${NC}"
  echo -e "MongoDB path:           ${YELLOW}$MONGO_PATH${NC}"
  echo -e "Versity Gateway path:   ${YELLOW}$VERSITYGW_PATH${NC}"
  echo -e "Dry run:                ${YELLOW}$DRY_RUN${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

load_env_paths
print_summary
confirm_cleanup
stop_docker_resources
remove_config_paths
remove_container_images
remove_data_paths
remove_script_paths

echo -e "${GREEN}✅ Remote Falcon cleanup complete.${NC}"
