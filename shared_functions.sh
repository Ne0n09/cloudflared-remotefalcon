#!/bin/bash

# SHARED_FUNCTIONS_VERSION=2025.9.8.1

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

# Validate GitHub user, accepts the GITHUB_PAT as an argument
validate_github_user() {
  local github_pat="$1"
  echo -e "🔍 Validating GitHub authentication..."

  # Ensure GitHub CLI is authenticated by trying to use the GITHUB_PAT from .env
  if ! gh auth status &>/dev/null; then
    if [[ -n "${github_pat:-}" ]]; then
      echo "🔑 Logging into GitHub CLI using GITHUB_PAT from .env..."

      # Logout first (quiet, ignore errors if not logged in)
      gh auth logout --hostname github.com &>/dev/null || true

      if ! echo "$github_pat" | gh auth login --with-token 2>/tmp/gh_login_err; then
        echo -e "${RED}❌ GitHub CLI login failed.${NC}"
        cat /tmp/gh_login_err
        return 1
      fi
    else
      echo -e "${RED}❌ Unable to login to GitHub CLI or GITHUB_PAT is not set in .env.${NC}"
      echo -e "You can authenticate the GitHub CLI by running: ${CYAN}gh auth login${NC}"
      return 1
    fi
  fi

  # Get GitHub username
  GH_USER=$(gh api user --jq '.login' 2>/dev/null)
  if [[ -z "$GH_USER" ]]; then
    echo -e "${RED}❌ GitHub username not detected from 'gh api user'.${NC}"
    return 1
  fi

  echo -e "${GREEN}✔ GitHub authentication for user '$GH_USER' validated successfully.${NC}"
  return 0
}

# Validate GitHub repo, must be done after validate_github_user
validate_github_repo() {
  local target_repo="$1"  # GitHub repo in format username/repo
  echo -e "🔍 Validating GitHub repository '$target_repo' access..."

  # Validate target repo exists
  if ! gh repo view "$target_repo" >/dev/null 2>&1; then
    echo -e "${RED}❌ GitHub repository '$target_repo' does not exist or you do not have access.${NC}"
    return 1
  fi
  echo -e "${GREEN}✔ GitHub repository '$target_repo' access validated successfully.${NC}"
  return 0
}

# Validate Docker user, must be done after validate_github_user
validate_docker_user() {
  echo -e "🔍 Validating GHCR login..."

  # Get GitHub username, username is required for Docker login
  GH_USER=$(gh api user --jq '.login' 2>/dev/null)
  if [[ -z "$GH_USER" ]]; then
    echo -e "${RED}❌ GitHub username not detected from 'gh api user'.${NC}"
    return 1
  fi

  # Attempt Docker login to GHCR
  echo "$GITHUB_PAT" | sudo docker login ghcr.io -u "$GH_USER" --password-stdin >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}❌ Docker login to ghcr.io failed for user $GH_USER. Are you missing GITHUB_PAT in $ENV_FILE?${RED}"
    return 1
  fi

  echo -e "${GREEN}✔ GHCR login validated successfully.${NC}"
  return 0
}

# Updates the VERSION in the .env file so you can see the current version on the RF control panel
update_rf_version() {
  NEW_VERSION=$(date +'%Y.%m.%-d')
  if [[ -f "$ENV_FILE" ]]; then
    if grep -q "^VERSION=" "$ENV_FILE"; then
      sed -i "s/^VERSION=.*/VERSION=$NEW_VERSION/" "$ENV_FILE"
    else
      echo "VERSION=$NEW_VERSION" >> "$ENV_FILE"
    fi
    return 0
  else
    echo -e "${RED}❌ update_rf_version error: $ENV_FILE not found.${NC}"
    return 1
  fi
}

# Function to update the compose image path if $REPO is configured in the .env to allow for local builds or pulling from GHCR
update_compose_image_path() {
  local containers=("plugins-api" "control-panel" "viewer" "ui" "external-api")
  local before after

  # Store hash before modifications
  before=$(md5sum "$COMPOSE_FILE")

  if [[ -z "$REPO" || "$REPO" = "username/repo" ]]; then
    # Remove ghcr.io/${REPO}/ prefix
    sed -i 's|ghcr.io/${REPO}/||g' "$COMPOSE_FILE"
  else
    # Ensure literal ghcr.io/${REPO}/ prefix is present
    for service in "${containers[@]}"; do
      # Normalize both unprefixed and already-prefixed lines to the canonical form
      sed -i -E "s|(^[[:space:]]*image:[[:space:]]*\"?)((${service}:[^\"[:space:]]+))(\"?)|\1ghcr.io/\${REPO}/\2\4|" "$COMPOSE_FILE"
    done
  fi

  # Store hash after modifications
  after=$(md5sum "$COMPOSE_FILE")

  # Only display message if changes occurred
  if [[ "$before" != "$after" ]]; then
    if [[ -n "$REPO" && "$REPO" != "username/repo" ]]; then
      echo -e "${BLUE}🐙 REPO is configured, 'ghcr.io/\${REPO}/' image: prefixes updated in $COMPOSE_FILE.${NC}"
    else
      echo -e "${BLUE}🐙 REPO is not configured, 'ghcr.io/\${REPO}/' image: prefixes removed from $COMPOSE_FILE.${NC}"
    fi
  fi
}

# Function to check system memory and if less than 16GB display a warning message about building locally
memory_check() {
  # Required memory in kB (15 GB = 16 * 1024 * 1024) - Slightly less than 16GB as it will likely report 15.xGB
  required_kb=$((15 * 1024 * 1024))

  # Read MemTotal from /proc/meminfo
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

  # Convert to GB for display
  mem_gb=$((mem_kb / 1024 / 1024))

  if (( mem_kb < required_kb )); then
    echo -e "⚠️ ${YELLOW}Warning: System has only ${mem_gb}GB of RAM. The images for 'plugins-api' and 'viewer' may fail to build with less than 16GB of RAM!"
    return 1
  else
    #echo -e "✅ ${GREEN}Memory check passed:${NC} ${mem_gb} GB detected."
    return 0
  fi
}

# Function to match compose service name with container name to handle the special case of minio
get_container_name() {
  local service_name="$1"
  case "$service_name" in
    minio)
      echo "remote-falcon-images.minio"
      ;;
    *)
      echo "$service_name"
      ;;
  esac
}

# Function to fetch current version directly from the container when it is running.
get_current_version() {
  local service_name=$1

  case "$service_name" in
    plugins-api|control-panel|viewer|ui|external-api)
      sudo docker ps --filter "name=$(get_container_name "$service_name")" --format '{{.Image}}' | sed -E 's|^.*:||'
      ;;
    cloudflared)
      sudo docker exec "$(get_container_name "$service_name")" cloudflared --version | sed -n 's/^cloudflared version \([0-9.]*\).*/\1/p'
      ;;
    nginx)
      sudo docker exec "$(get_container_name "$service_name")" nginx -v 2>&1 | sed -n 's/^nginx version: nginx\///p'
      ;;
    mongo)
      sudo docker exec "$(get_container_name "$service_name")" bash -c "mongod --version | grep -oP 'db version v\\K[\\d\\.]+'" | tr -d '[:space:]'
      ;;
    minio)
      sudo docker exec "$(get_container_name "$service_name")" minio --version | sed -n 's/^minio version \(RELEASE\.[^ ]\+\).*/\1/p'
      ;;
    *)
      echo -e "${RED}❌ Failed to get current version. Unsupported container: $service_name${NC}" >&2
      exit 1
      ;;
  esac
}

# Function to get the current compose tag
get_current_compose_tag() {
  local service_name="$1"
  local current_tag

  current_tag=$(grep -m1 -E "^[[:space:]]*image:.*${service_name}:" "$COMPOSE_FILE" | sed -E "s|.*${service_name}:([^\" ]+).*|\1|")

  if [[ -z "$current_tag" ]]; then
    echo "undetermined"
  else
    echo "$current_tag"
  fi
}

# Function to replace the compose tag with version for a given service
replace_compose_tag() {
  local service_name="$1"
  local tag="$2"

  case "$service_name" in
    plugins-api|control-panel|viewer|ui|external-api)
      # If full commit is passed then update the build context line in compose.yaml to allow local builds from the correct commit
      if (( ${#tag} > 7 )); then
        sed -i.bak -E "s|(context: https://github.com/Remote-Falcon/remote-falcon-${service_name}\.git)(#.*)?|\1#$tag|g" "$COMPOSE_FILE"
      fi

      tag=${tag:0:7} # Ensures that we use short sha for image tag if full commit is passed
      sed -i -E "s|(^[[:space:]]*image:[[:space:]]*\"?)([^\"[:space:]]*${service_name}):[^\"[:space:]]+(\"?)|\1\2:${tag}\3|" "$COMPOSE_FILE"
      ;;
    cloudflared)
      sed -i.bak -E "s|cloudflare/$service_name:[^[:space:]]+|cloudflare/$service_name:$tag|" "$COMPOSE_FILE"
      ;;
    nginx)
      sed -i.bak -E "/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$tag|" "$COMPOSE_FILE"
      ;;
    mongo)
      sed -i.bak -E "/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$tag|" "$COMPOSE_FILE"
      ;;
    minio)
      sed -i.bak -E "s|minio/minio:[^[:space:]]+|minio/minio:$tag|" "$COMPOSE_FILE"
      ;;
    *)
      echo -e "${RED}❌ Failed to replace compose tags. Unsupported container: $service_name${NC}" >&2
      exit 1
      ;;
  esac
}

# Check the version is in the valid version format and not set to 'latest' or other invalid formats
check_tag_format() {
  local service_name="$1"
  local tag="$2"
  local format_regex
  local format

  case "$service_name" in
    plugins-api|control-panel|viewer|ui|external-api)
      format_regex="\b[0-9a-f]{7}\b"
      format="abcd123"
      ;;
    cloudflared)
      format_regex="^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$"
      format="XXXX.XX.X"
      ;;
    nginx)
      format_regex="^[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}$"
      format="XX.XX.XX"
      ;;
    mongo)
      format_regex="^[0-9]{1,2}\.[0-9]+\.[0-9]{1,2}$" 
      format="XX.X.XX"
      ;;
    minio)
      format_regex="^RELEASE\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$"
      format="RELEASE.YYYY-MM-DDTHH-MM-SSZ"
      ;;
    *)
      echo -e "${RED}❌ Failed to check version format. Unsupported container: $service_name${NC}" >&2
      exit 1
      ;;
  esac

  if [[ $tag =~ $format_regex ]]; then
    # Return valid format
    return 0
  else
    # Return invalid format
    # echo -e "${YELLOW}⚠️ $service_name current version $tag is not in the valid format ($format).${NC}"
    return 1
  fi
}

is_container_running() {
  local service_name="$1"

  sudo docker compose -f "$COMPOSE_FILE" ps --services --filter "status=running" | grep -q "^${service_name}$"
}

# ========== END Shared Functions ==========