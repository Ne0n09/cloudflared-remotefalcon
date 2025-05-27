#!/bin/bash

# SHARED_FUNCTIONS_VERSION=2025.5.27.1

# ========== START Shared Config ==========
# Configuration variables that are re-used across multiple scripts
# Get the directory where the script is located and set the RF directory to 'remotefalcon'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RF_DIR="remotefalcon"
WORKING_DIR="$SCRIPT_DIR/$RF_DIR"
BACKUP_DIR="$SCRIPT_DIR/remotefalcon-backups"
COMPOSE_FILE="$WORKING_DIR/compose.yaml"
ENV_FILE="$WORKING_DIR/.env"
HEALTH_CHECK_SCRIPT="$SCRIPT_DIR/health_check.sh"
MINIO_ALIAS="minio"
BUCKET_NAME="remote-falcon-images"
ACCESS_KEY_NAME="remote-falcon-key"

# Used to store .env variables
declare -gA existing_env_vars
declare -ga original_keys

# ========== Color Codes ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========== END Shared Config ==========
# ========== START Shared Functions ==========
# Run health check script if argument 'health' is passed
health_check() {
  local health="$1"
  if [[ -x "$HEALTH_CHECK_SCRIPT" && $health == "health" ]]; then
    "$HEALTH_CHECK_SCRIPT"
  fi
}

check_compose_exists() {
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo -e "${RED}❌ Error: $COMPOSE_FILE not found.${NC}"
    exit 1
  fi
}

check_env_exists() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}❌ Error: $ENV_FILE not found.${NC}"
    exit 1
  fi
}

# ====== Parse a .env File ======
# Usage: parse_env [filename]
parse_env() {
  local env_file="${1:-$ENV_FILE}"
  original_keys=() # Reset if re-parsing

  if [[ ! -f "$env_file" ]]; then
    echo -e "${RED}❌ .env file not found: $env_file${NC}"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^\s*# || -z "$line" ]] && continue # Skip comments and empty lines

    # Split the line into key and value
    local key="${line%%=*}"
    local value="${line#*=}"

    [[ "$key" == "$value" ]] && value=""

    existing_env_vars["$key"]="$value"
    original_keys+=("$key")

    export "$key"="$value" # Export the variable for auto-completion
  done < "$env_file"
}
# ====== Print the Parsed Env Variables ======
print_env() {
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  for key in "${original_keys[@]}"; do
    echo -e "${BLUE}🔹 $key${NC}=${YELLOW}${existing_env_vars[$key]}${NC}"
  done
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Backup the existing .env/compose.yaml file in case roll-back is needed
backup_file() {
  local file_path="$1"
  local filename=$(basename "$file_path")

  timestamp=$(date +'%Y-%m-%d_%H-%M-%S')
  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo -e "${YELLOW}⚠️ Directory '$BACKUP_DIR' does not exist. Creating it in $SCRIPT_DIR...${NC}"
    mkdir "$BACKUP_DIR"
  fi

  cp "$file_path" "$BACKUP_DIR/$filename.backup-$timestamp"
  echo -e "${GREEN}✔ Backed up $file_path to $BACKUP_DIR/$filename.backup-$timestamp${NC}"
}
# ========== END Shared Functions ==========