#!/bin/bash

# SHARED_FUNCTIONS_VERSION=2025.6.9.1

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

# Function to backup the MongoDB database
backup_mongo() {
  # Define container name and backup directory
  local service_name="$1"

  # Load environment variables from .env file
  if [ -f "$ENV_FILE" ]; then
    parse_env
  else
    echo -e "${RED}❌ Error: $ENV_FILE not found.${NC}"
    exit 1
  fi

  # Check if required variables are set
  if [ -z "$MONGO_PATH" ]; then
    echo -e "${RED}❌ Error: MONGO_PATH not set in the .env file.${NC}"
    exit 1
  fi

  # Check MONGO_URI in the .env file is in the valid format
  if [[ ! "$MONGO_URI" =~ ^mongodb:\/\/[^:@]+:[^:@]+@[^:\/]+:[0-9]+\/[^?]+(\?.*)?$ ]]; then
    echo -e "${RED}❌ Error: MONGO_URI is not in the valid format (mongodb://user:pass@host:27017/dbname?authSource=admin).${NC}"
    exit 1
  fi

  # Get the DB name from the MONGO_URI
  db_name="${MONGO_URI##*/}"
  db_name="${db_name%%\?*}"

  # Generate a backup filename with date
  mongo_backup_file="$BACKUP_DIR/mongo_${CURRENT_VERSION}_${db_name}_backup_$(date +'%Y-%m-%d_%H-%M-%S').gz"

  echo "Creating backup of the '$db_name' database from container '$service_name'..."

  sudo docker exec "$(get_container_name "$service_name")" mongodump --archive=/tmp/backup.archive --gzip --db $db_name --username $MONGO_INITDB_ROOT_USERNAME --password $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin

  # Copy the backup file from the container to the local machine
  sudo docker cp "$(get_container_name "$service_name")":/tmp/backup.archive $mongo_backup_file

  # Confirm completion and cleanup
  if [ -f "$mongo_backup_file" ]; then
    echo -e "${GREEN}✔ Mongo DB '$db_name' backed up to $mongo_backup_file${NC}"
    sudo docker exec "$(get_container_name "$service_name")" rm /tmp/backup.archive  # Clean up temporary backup file inside the container
  else
    echo -e "${RED}❌ Backup failed. Please check the container logs for more information.${NC  }"
    exit 1
  fi
}

# ========== END Shared Functions ==========