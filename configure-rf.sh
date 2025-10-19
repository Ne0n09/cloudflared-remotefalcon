#!/bin/bash

# VERSION=2025.10.19.1

#set -euo pipefail

CONFIGURE_RF_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/configure-rf.sh"

# Set the URLs to download the compose.yaml, NGINX default.conf, and default .env files
SHARED_FUNCTIONS_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/shared_functions.sh"
DOCKER_COMPOSE_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/remotefalcon/compose.yaml"
NGINX_DEFAULT_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/remotefalcon/default.conf"
DEFAULT_ENV_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/remotefalcon/.env"
UPDATE_CONTAINERS_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/update_containers.sh"
HEALTH_CHECK_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/health_check.sh"
MINIO_INIT_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/minio_init.sh"
RUN_WORKFLOW_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/run_workflow.sh"
SYNC_REPO_SECRETS_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/sync_repo_secrets.sh"
SERVICES=(external-api ui plugins-api viewer control-panel cloudflared nginx mongo minio)
ANY_SERVICE_RUNNING=false
TEMPLATE_REPO="Ne0n09/remote-falcon-image-builder" # Template repo for image builder workflows

# new_build_args array to track if any build args changed that would require RF container rebuild
# For GHCR builds these get synced with sync_repo_secrets.sh
# "CONTROL_PANEL_API" "VIEWER_API" not included because we only want to track if DOMAIN is changed
#### This will need to be updated down in update_env() if any new build context args are added - sync_repo_secrets will also need to be updated

# Function to download file if it does not exist
download_file() {
  local url=$1
  local filename=$2

  if [ ! -f "$filename" ]; then
    echo -e "${YELLOW}⚠️ $filename does not exist. Downloading $filename...${NC}"
    if curl -O "$url"; then
      echo -e "✔ ${GREEN}Downloaded $filename successfully.${NC}"
    else
      echo -e "${RED}❌ Failed to download $filename from $url.${NC}"
      exit 1
    fi
  fi
}

echo -e "${BLUE}⚙️ Running ${RED}RF${NC} configuration script...${NC}"

# Download and source shared functions
download_file $SHARED_FUNCTIONS_URL "shared_functions.sh"
chmod +x "shared_functions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/shared_functions.sh" ]]; then
  echo -e "${RED}❌ ERROR: shared_functions.sh does not exist in $SCRIPT_DIR.${NC}"
  exit 1
fi
source "$SCRIPT_DIR/shared_functions.sh"

# Download extra helper scripts if they do not exist and make them executable
download_file $UPDATE_CONTAINERS_URL "update_containers.sh"
download_file $HEALTH_CHECK_URL "health_check.sh"
download_file $MINIO_INIT_URL "minio_init.sh"
download_file $RUN_WORKFLOW_URL "run_workflow.sh"
download_file $SYNC_REPO_SECRETS_URL "sync_repo_secrets.sh"
chmod +x "shared_functions.sh" "update_containers.sh" "health_check.sh" "minio_init.sh" "run_workflow.sh" "sync_repo_secrets.sh"

## Check for script updates
BASE_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main"

# Mapping of files to their version tag patterns
declare -A FILES=(
  [configure-rf.sh]="VERSION="
  [update_containers.sh]="VERSION="
  [health_check.sh]="VERSION="
  [sync_repo_secrets.sh]="VERSION="
  [minio_init.sh]="VERSION="
  [run_workflow.sh]="VERSION="
  [compose.yaml]="COMPOSE_VERSION="
  [.env]="ENV_VERSION="
  [default.conf]="VERSION="
)

# Function to display and check for updates to the helper scripts with a prompt to upddate all that are out of date
update_scripts() {
  echo -e "${CYAN}📜 Checking for script updates...${NC}"
  local outdated_scripts=()

  printf "%-25s %-15s %-15s %-7s\n" "File" "Local Version" "Remote Version" "Status"
  printf "%-25s %-15s %-15s %-7s\n" "─────────────────────────" "───────────────" "───────────────" "───────"

  for file in configure-rf.sh update_containers.sh health_check.sh sync_repo_secrets.sh minio_init.sh run_workflow.sh; do
    pattern="${FILES[$file]}"
    local_file="$SCRIPT_DIR/$file"
    local_ver="N/A"
    if [[ -f "$local_file" ]]; then
      local_ver=$(grep -Eo "^# ${pattern}[0-9.]+" "$local_file" | head -n1 | sed -E "s/^# ${pattern}//" | tr -d '\r')
    fi

    remote_ver=$(curl -fsSL "$BASE_URL/$file" 2>/dev/null | grep -Eo "^# ${pattern}[0-9.]+" | head -n1 | sed -E "s/^# ${pattern}//" | tr -d '\r')

    if [[ -z "$remote_ver" ]]; then
      status="⚠️  Skipped"
    elif [[ "$local_ver" == "$remote_ver" ]]; then
      status="✅ OK"
    else
      status="🔄 Update"
      outdated_scripts+=("$file")
    fi

    printf "🔹 %-23s %-15s %-15s %-7s\n" "$file" "$local_ver" "$remote_ver" "$status"
  done

  if [[ ${#outdated_scripts[@]} -eq 0 ]]; then
    echo -e "\n${GREEN}All scripts are up to date!${NC}"
    return
  fi

  echo -e "${BLUE}🔗 Release notes: https://ne0n09.github.io/cloudflared-remotefalcon/release-notes/${NC}"
  read -rp $'\nWould you like to update all outdated scripts now? (y/n): ' ans
  [[ ! "$ans" =~ ^[Yy]$ ]] && echo -e "${YELLOW}Skipped script updates.${NC}" && return

  echo -e "\n⬇️  Updating outdated scripts...\n"

  for file in "${outdated_scripts[@]}"; do
    local_file="$WORKING_DIR/$file"
    echo -e "→ Updating $file..."
    backup_file "$local_file"
    curl -fsSL "$BASE_URL/remotefalcon/$file" -o "$local_file"
    chmod +x "$local_file"

    new_ver=$(grep -Eo "^# ${FILES[$file]}[0-9.]+" "$local_file" | head -n1 | sed -E "s/^# ${FILES[$file]}//" | tr -d '\r')
    echo -e "${GREEN}✅ $file updated to version ${YELLOW}$new_ver${NC}\n"
  done
}

update_scripts

# Function to get user input for configuration questions
get_input() {
  local prompt="$1"
  local default="$2"
  local input

  read -rp "$prompt [$default]: " input
  echo "${input:-$default}"
}

# Function to update the the .env file with required variables to run RF and some optional variables
update_env() {
  pending_changes=false # This is to track if any .env values would change
  pending_arg_changes=false # This is to track if any BUILD args would change

  # Declare NEW variables to check against existing .env values to detect if anything changed
  declare -A new_env_vars=(
    ["REPO"]="$repo"
    ["TUNNEL_TOKEN"]="$tunneltoken"
    ["DOMAIN"]="$domain"
#    ["HOSTNAME_PARTS"]="$hostnameparts"
    ["AUTO_VALIDATE_EMAIL"]="$autovalidateemail"
#    ["NGINX_CONF"]="$NGINX_CONF"
    ["NGINX_CERT"]="./${domain}_origin_cert.pem"
    ["NGINX_KEY"]="./${domain}_origin_key.pem"
#    ["HOST_ENV"]="$HOST_ENV"
    ["GOOGLE_MAPS_KEY"]="$googlemapskey"
    ["PUBLIC_POSTHOG_KEY"]="$publicposthogkey"
    ["GA_TRACKING_ID"]="$gatrackingid"
    ["MIXPANEL_KEY"]="$mixpanelkey"
#    ["CLIENT_HEADER"]="$CLIENT_HEADER"
#    ["SENDGRID_KEY"]="$SENDGRID_KEY"
    ["GITHUB_PAT"]="$githubpat"
    ["SOCIAL_META"]="$socialmeta"
    ["SEQUENCE_LIMIT"]="$sequencelimit"
    ["SWAP_CP"]="$swapCP"
    ["VIEWER_PAGE_SUBDOMAIN"]="$viewerPageSubdomain"
    ["CLARITY_PROJECT_ID"]="$clarity_project_id"
  )

  # If any of these are changed, an image rebuild will be required.
  declare -A new_build_args=(
    ["VERSION"]="$version"
    ["HOST_ENV"]="$hostenv"
    ["DOMAIN"]="$domain"
    ["GOOGLE_MAPS_KEY"]="$googlemapskey"
    ["PUBLIC_POSTHOG_KEY"]="$publicposthogkey"
    ["PUBLIC_POSTHOG_HOST"]="$publicposthoghost"
    ["GA_TRACKING_ID"]="$gatrackingid"
    ["MIXPANEL_KEY"]="$mixpanelkey"
    ["HOSTNAME_PARTS"]="$hostnameparts"
    ["SOCIAL_META"]="$socialmeta"
    ["SWAP_CP"]="$swapCP"
    ["VIEWER_PAGE_SUBDOMAIN"]="$viewerPageSubdomain"
    ["OTEL_OPTS"]="$otelopts"
    ["OTEL_URI"]="$oteluri"
    ["MONGO_URI"]="$mongouri"
    ["CLARITY_PROJECT_ID"]="$clarity_project_id"
  )

  for key in "${!new_env_vars[@]}"; do
    current_val=$(grep -E "^${key}=" .env | cut -d'=' -f2-)
    if [[ "${new_env_vars[$key]}" != "$current_val" ]]; then
      pending_changes=true
      break
    fi
  done

  for key in "${!new_build_args[@]}"; do
    current_val=$(grep -E "^${key}=" .env | cut -d'=' -f2-)
    if [[ "${new_build_args[$key]}" != "$current_val" ]]; then
      pending_arg_changes=true
      break
    fi
  done

  if [ "$pending_changes" = false ]; then
    echo -e "${YELLOW}⚠️ No changes detected — skipping .env update prompt.${NC}"
    return 1
  else
    # Print all answers before asking to update the .env file
    echo
    echo -e "${YELLOW}⚠️ Please confirm the values below are correct:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    # Iterate over the original order of keys
    for key in "${original_keys[@]}"; do
      if [[ -v new_env_vars[$key] ]]; then  # Ensures empty values are displayed
        echo -e "${RED}🔸 $key${NC}=${YELLOW}${new_env_vars[$key]}${NC}"
      fi
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$pending_arg_changes" = true ]; then
      echo
      echo -e "${YELLOW}⚠️ The following build arguments have changed. Remote Falcon container images will need to be (re)built for the changes to take effect:${NC}"
      echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      for key in "${original_keys[@]}"; do
        if [[ -v new_build_args[$key] ]]; then
          current_val=$(grep -E "^${key}=" .env | cut -d'=' -f2-)
          if [[ "${new_build_args[$key]}" != "$current_val" ]]; then
            echo -e "${RED}🔧 $key${NC}=${YELLOW}${new_build_args[$key]}${NC}"
          fi
        fi
      done
      echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
  fi

  # Write the variables to the .env file if answer is y
  if [[ "$(get_input "❓ Update the .env file with the above values? (y/n)" "n" )" =~ ^[Yy]$ ]]; then
    # Backup the existing .env file in case roll-back is needed
    timestamp=$(date +'%Y-%m-%d_%H-%M-%S')
    if [[ ! -d "$BACKUP_DIR" ]]; then
      cp .env "$WORKING_DIR/.env.backup-$timestamp"
      echo -e "${YELLOW}⚠️ $BACKUP_DIR does not exist, backed up current .env to $WORKING_DIR/.env.backup-$timestamp${NC}"
    else
      cp .env "$BACKUP_DIR/.env.backup-$timestamp"
      echo -e "${GREEN}✔ Backed up current .env to $BACKUP_DIR/.env.backup-$timestamp${NC}"
    fi

    # Refresh the JWT keys when the prompt above is accepted
    new_env_vars["VIEWER_JWT_KEY"]="$(openssl rand -base64 32)"
    new_env_vars["USER_JWT_KEY"]="$(openssl rand -base64 32)"

    # Ensure .env ends with a newline before appending
    if [ -s .env ] && [ "$(tail -c1 .env)" != "" ]; then
      echo >> .env
    fi

    # Update the .env file
    for key in "${!new_env_vars[@]}"; do
      if grep -q "^${key}=" .env; then
        # Use sed to update the existing key, correctly handling empty values
        sed -i "s|^${key}=.*|${key}=${new_env_vars[$key]}|" .env
      else
        # Append only if it doesn’t exist in the .env file
        echo "${key}=${new_env_vars[$key]}" >> .env
      fi
    done

    # Remove any duplicate lines in the .env file
    awk '!seen[$0]++' .env > .env.tmp && mv .env.tmp .env

    echo -e "${GREEN}✔ Writing variables to .env file completed!${NC}"
    echo
    echo "Printing current .env variables:"
    parse_env "$ENV_FILE"
    print_env

    # If there's pending arg changes set image_reubild_needed to true since the changes were accepted and written to .env
    if [ "$pending_arg_changes" = true ]; then
      image_rebuild_needed=true
    fi

    return 0 # Return Success
  else
    echo -e "${YELLOW}⚠️ Variables were not updated! No changes were made to the .env file.${NC}"
    return 1 # Return Failure
  fi
}

# Check for updates to the containers
run_updates() {
  local update_mode="${1:-}"

  if [[ -z "$update_mode" ]]; then
    update_mode="interactive"  # Default to interactive mode if not provided
  fi

  if [[ -z "$TUNNEL_TOKEN" || "$TUNNEL_TOKEN" == "cloudflare_token" ]]; then
    echo -e "${RED}❌ Cloudflared token is missing or still set to a placeholder. Re-run configure-rf.sh to configure.${NC}"
    exit 1
  fi
  if [[ "$DOMAIN" == "your_domain.com" || -z "$DOMAIN" ]]; then
    echo -e "${RED}❌ 'your_domain.com' is a placeholder. Please enter a valid domain.${NC}"
    exit 1
  elif [[ ! "$DOMAIN" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    echo -e "${RED}❌ '$DOMAIN' is not a valid domain format.${NC}"
    exit 1
  fi

  echo -e "${YELLOW}⚠️ Checking for container updates...${NC}"
  case "$update_mode" in
    auto-apply)
      bash "$SCRIPT_DIR/update_containers.sh" "all" "auto-apply"
      ;;
    *)
      # Interactive mode, default
      bash "$SCRIPT_DIR/update_containers.sh" "all"
      ;;
  esac

  # Check if the minio_init.sh script exists and run it if it any of the MinIO credentials are set to default values
  if [[ $MINIO_ROOT_USER == "12345678" || $MINIO_ROOT_PASSWORD == "12345678" || $S3_ACCESS_KEY == "123456" || $S3_SECRET_KEY == "123456" ]]; then
    echo -e "${YELLOW}⚠️ MinIO variables are set to the default values. Running minio_init.sh to configure MiniO...${NC}"
    if [ -f "$SCRIPT_DIR/minio_init.sh" ]; then
      bash "$SCRIPT_DIR/minio_init.sh"
    else
      echo -e "${YELLOW}⚠️ minio_init.sh script not found. Skipping MinIO initialization.${NC}"
    fi
  fi
  health_check health
}

# Function to list helper script versions
list_script_versions() {
  echo -e "${BLUE}📜 Existing script versions:${NC}"
  grep -H '^# *VERSION=' ./*.sh | while IFS=: read -r file line; do
    version=$(echo "$line" | sed -E 's/^# *VERSION=//')
    filename=$(basename "$file")
    printf "🔹 %-25s ${YELLOW}%s${NC}\n" "$filename" "$version"
  done
}

# Function to list version of compose, .env, and default.conf files
list_file_versions() {
  echo -e "${BLUE}📜 Existing file versions:${NC}"
  awk -v YELLOW="$YELLOW" -v NC="$NC" '
    FILENAME ~ /compose.yaml$/ && $0 ~ /^[[:space:]]*#?[[:space:]]*COMPOSE_VERSION=/ {
      gsub(/^[[:space:]]*#?[[:space:]]*COMPOSE_VERSION=[[:space:]]*/, "", $0)
      printf "🔹 %-24s %s%s%s\n", FILENAME, YELLOW, $0, NC
    }
    FILENAME ~ /\.env$/ && $0 ~ /^[[:space:]]*#?[[:space:]]*ENV_VERSION=/ {
      gsub(/^[[:space:]]*#?[[:space:]]*ENV_VERSION=[[:space:]]*/, "", $0)
      printf "🔹 %-24s %s%s%s\n", FILENAME, YELLOW, $0, NC
    }
    FILENAME ~ /default.conf$/ && $0 ~ /^[[:space:]]*#?[[:space:]]*VERSION=/ {
      gsub(/^[[:space:]]*#?[[:space:]]*VERSION=[[:space:]]*/, "", $0)
      printf "🔹 %-24s %s%s%s\n", FILENAME, YELLOW, $0, NC
    }
  ' compose.yaml .env default.conf
}

repo_init() {
  local username="$1"   # GitHub username
  local new_repo="$2"   # Repo name (without username)

  # Convert both to lowercase
  username="${username,,}"
  new_repo="${new_repo,,}"

  echo -e "${BLUE}➕ Attempting to create private repository '$username/$new_repo' from template '$TEMPLATE_REPO'...${NC}"

  # Create repo from template
  if ! gh repo create "$username/$new_repo" --private --disable-issues --template "$TEMPLATE_REPO"; then
    echo -e "${RED}❌ Failed to create repository '$username/$new_repo'. Please check your GitHub PAT permissions and try again.${NC}"
    return 1
  fi

  # For updating the REPO value in the .env file
  repo="${username}/${new_repo}"

  # Disable projects quietly since projects is not really needed on the new repo
  gh repo edit "$username/$new_repo" --enable-projects=false &>/dev/null || true

  echo -e "${GREEN}✅ Repository '$username/$new_repo' created and $ENV_FILE updated!${NC}"
}

# Function to check extracted tags to check if they are tagged to 'latest'
tag_has_latest() {
  for service in "${SERVICES[@]}"; do

    if [[ $(get_current_compose_tag "$service") == "latest" ]]; then
      return 0  # true = has at least one 'latest'
    fi
  done

  return 1  # false = no 'latest'
}

# Check if user is root or in the sudo group
if [[ $EUID -eq 0 ]]; then
  # User is root, do nothing
  :
elif id -nG "$USER" | grep -qw "sudo"; then
  # User is in the sudo group, do nothing
  :
else
  echo -e "${YELLOW}⚠️ User '$USER' is NOT root and NOT part of the sudo group.${NC}"
  echo "You must add the user '$USER' to the sudo group or run the script as root."
  echo
  echo "To add a user to the sudo group, usually you can run the following commmands..."
  echo "Switch to the root user: su root"
  echo "Add the user to the sudo group: /sbin/usermod -aG sudo $USER"
  echo "Switch back to the user: su $USER"
  exit 1
fi

# Check if Docker is installed and ask to download and install it if not (For Ubuntu and Debian).
if ! command -v docker >/dev/null 2>&1; then
  if [[ "$(get_input "Docker is not installed, would you like to install it? (y/n)" "y")" =~ ^[Yy]$ ]]; then
    echo "Installing docker... you may need to enter your password for the 'sudo' command."
    # Get OS distribution
    source /etc/os-release
    case $ID in
      ubuntu)
        echo "Installing Docker for Ubuntu..."
        sudo apt-get update && sudo apt-get install ca-certificates curl && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        if ! command -v docker >/dev/null 2>&1; then
          echo -e "${RED}❌ Docker install failed. Please install Docker to proceed.${NC}"
          exit 1
        else
          echo -e "${GREEN}✅ Docker installation for Ubuntu complete!${NC}"
        fi
      ;;
      debian)
        echo "Installing Docker for Debian.."
        sudo apt-get update && sudo apt-get install ca-certificates curl && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        if ! command -v docker >/dev/null 2>&1; then
          echo -e "${RED}❌ Docker install failed. Please install Docker to proceed.${NC}"
          exit 1
        else
          echo -e "${GREEN}✅ Docker installation for Debian complete!${NC}"
        fi
      ;;
      *) echo -e "${RED}❌ Distribution is not supported by this script! Please install Docker manually.${NC}"
      ;;
    esac
  else
    echo -e "${RED}❌ Docker must be installed. Please re-run the script to install Docker and to proceed.${NC}"
    exit 1
  fi
  echo
fi

# Check if GitHub CLI (gh) is installed
if ! command -v gh >/dev/null 2>&1; then
  echo "Installing GitHub CLI (gh)... you may need to enter your password for the 'sudo' command."
  (type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && sudo mkdir -p -m 755 /etc/apt/sources.list.d \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update \
  && sudo apt install gh -y
  if ! command -v gh >/dev/null 2>&1; then
    echo -e "${RED}❌ GitHub CLI (gh) install failed. Please install GitHub CLI (gh) to proceed.${NC}"
    exit 1
  else
    echo -e "${GREEN}✅ GitHub CLI (gh) installation complete!${NC}"
    fi
fi

# Auto install jq if not installed
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${YELLOW}⚠️ 'jq' is not installed. Installing jq...${NC}"
  sudo apt-get update && sudo apt-get install -y jq
fi

# Get the downloaded script versions and display them
#list_script_versions

# Ensure the 'remotefalcon' directory exists
if [ ! -d "$WORKING_DIR" ]; then
  echo -e "${YELLOW}⚠️ Directory '$RF_DIR' does not exist. Creating it in $SCRIPT_DIR...${NC}"
  mkdir "$WORKING_DIR"
fi

# Ensure the 'backup' directory exists
if [ ! -d "$BACKUP_DIR" ]; then
  echo -e "${YELLOW}⚠️ Directory '$BACKUP_DIR' does not exist. Creating it in $SCRIPT_DIR...${NC}"
  mkdir "$BACKUP_DIR"
fi

# Change to the 'remotefalcon' directory and download compose.yaml and default.conf if they do not exist
cd "$WORKING_DIR" || { echo -e "${RED}❌ Failed to change directory to '$WORKING_DIR'. Exiting.${NC}"; exit 1; }
echo "✔  Working in directory: $(pwd)"
download_file $DOCKER_COMPOSE_URL "compose.yaml"
download_file $NGINX_DEFAULT_URL "default.conf"

# Print existing .env file, if it exists, otherwise download the default .env file
if [ -f .env ]; then
  echo "✔  Found existing .env at $ENV_FILE."
#  list_file_versions
  echo "🔍 Parsing current .env variables:"
else
  download_file $DEFAULT_ENV_URL ".env"
  list_file_versions
  echo "🔍 Parsing default .env variables:"
fi

# Read the .env file and export the variables, save build args to OLD_ARGS and print env file contents
parse_env "$ENV_FILE"
print_env

# Function for the GitHub configuration flow to configure GITHUB_PAT and REPO
configure_github() {
  # Get GITHUB_PAT and validate input is not default or empty
  while true; do
    githubpat=$(get_input "🔑 Enter your GitHub Personal Access Token, required scopes are 'read:org', 'read:packages', 'repo':" "$GITHUB_PAT")
    if [[ -z "$githubpat" ]]; then
      echo -e "${RED}❌ GitHub Personal Access Token cannot be blank.${NC}"
      continue
    elif [[ ! "$githubpat" =~ ^[0-9a-f]{40}$ ]] && [[ ! "$githubpat" =~ ^gh[pousr]_[A-Za-z0-9_]{36,255}$ ]]; then
      echo -e "${RED}❌ GitHub Personal Access Token is not in the correct format.${NC}"
    else
      break
    fi
  done

  # Only continue if PAT is set
  if [[ -n "$githubpat" ]]; then
    # Validate the GITHUB_PAT by using the GitHub CLI to login
    validate_github_user "$githubpat" || exit 1

    # Get the GitHub REPO name and then validate it exists or create it from template if it does not exist
    while true; do
      repo_input=$(get_input "🐙 Enter your GitHub Repository (either 'repo' or 'username/repo'). The username will be set to '$GH_USER':" "$REPO")

      # Reject blank/default
      if [[ -z "$repo_input" || "$repo_input" == "username/repo" || "$repo_input" == "repo" ]]; then
        echo -e "${RED}❌ Repository is blank or still set to default.${NC}"
        continue
      fi

      # Strip username if provided
      if [[ "$repo_input" == */* ]]; then
        repo_name="${repo_input#*/}"
      else
        repo_name="$repo_input"
      fi

      # Validate repo name format
      if [[ ! "$repo_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo -e "${RED}❌ Repository name may only contain letters, numbers, underscores, periods, or dashes.${NC}"
        continue
      fi

      # Normalize to lowercase
      username="${GH_USER,,}"
      repo_name="${repo_name,,}"

      # If repo does not exist, create it from template via repo_init, else set the repo variable to the correct format for the existing repo
      if ! validate_github_repo "$repo_name"; then
        if [[ "$(get_input "❓ Would you like to create private repository '$repo_name' from template 🔗 https://github.com/$TEMPLATE_REPO ? (y/n)" "y")" =~ ^[Yy]$ ]]; then     
          # Create from template if missing
          repo_init "$username" "$repo_name"
        fi
      else
        # set the temp repo value to the correct format, if user confirms at the update .env prompt it will be written to .env
        repo="${username}/${repo_name}"
      fi
      break
    done
  fi
}

# Ask to configure .env values
if [[ "$(get_input "❓ Change the .env file variables? (y/n)" "n" )" =~ ^[Yy]$ ]]; then
  # Configuration walkthrough questions. Questions will pull existing or default values from the sourced .env file
  echo
  echo -e "${YELLOW}⚠️ Answer the following questions to update your compose .env variables.${NC}"
  echo "Press ENTER to accept the existing values that are between the brackets [ ]."
  echo "You will be asked to confirm the changes before the file is modified."
  echo
  # ====== START variable questions ======

  # ====== START REQUIRED variables ======
  # If no repo is configured, display a warning message if less than 16GB of RAM is detected to encourage adding more RAM or confiure GitHub
  if [[ -z "$REPO" || "$REPO" == "username/repo" || ! "$REPO" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]]; then
    if ! memory_check; then
      echo -e "⚡ ${Yellow}If the images fail to build either add more system memory or configure GitHub for building images remotely.${NC}"
    fi
  fi
  if [[ "$(get_input "❓ Update GitHub configuration for building Remote Falcon images remotely on GitHub? (y/n)" "n")" =~ ^[Yy]$ ]]; then
    # If REPO is not blank or not the default ask to disable it, else ask to configure it
    if [[ -n "$repo" && "$repo" != "username/repo" ]]; then
      echo -e "${YELLOW}⚠️ Existing GitHub repository configuration found: $repo${NC}"
      if [[ "$(get_input "❓ Would you like to disable it and build images locally? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}⚠️ GITHUB_PAT and REPO will be set to default values if .env changes are accepted.${NC}"
        githubpat=" "
        repo="username/repo"
      else
        if [[ "$(get_input "❓ Modify the existing GitHub configuration to update the GITHUB_PAT or REPO? (y/n)" "n")" =~ ^[Yy]$ ]]; then
          configure_github
        fi
      fi
    else # REPO is blank or set to default
      if [[ "$(get_input "❓ Configure GITHUB_PAT and REPO for building Remote Falcon images remotely on GitHub? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        configure_github
      fi
    fi
  fi

  # Get the Cloudflared tunnel token and validate input is not default, empty, or not in valid format
  while true; do
    tunneltoken=$(get_input "🔐 Enter your Cloudflare Tunnel token:" "$TUNNEL_TOKEN")
    if [[ -z "$tunneltoken" || "$tunneltoken" == "cloudflare_token" ]]; then
      echo -e "${RED}❌ Token is missing or still set to a placeholder.${NC}"
    else
      break
    fi
  done

  # Get domain name and validate input is not default, empty, or not in valid domain format
  while true; do
    domain=$(get_input "🌐 Enter your domain name (e.g., yourdomain.com):" "$DOMAIN")
    if [[ "$domain" == "your_domain.com" || -z "$domain" ]]; then
      echo -e "${RED}❌ 'your_domain.com' is a placeholder. Please enter a valid domain.${NC}"
    elif [[ ! "$domain" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      echo -e "${RED}❌ '$domain' is not a valid domain format.${NC}"
    else
      break
    fi
  done

  # Validate auto validate email input, only accept true or false
  while true; do
    autovalidateemail=$(get_input "📧 Enable auto validate email? While set to 'true' anyone can create a viewer page account on your site (true/false):" "$AUTO_VALIDATE_EMAIL")
    autovalidateemail="${autovalidateemail,,}"  # lowercase
    if [[ "$autovalidateemail" == "true" || "$autovalidateemail" == "false" ]]; then
      break
    else
      echo -e "${RED}❌ Please enter 'true' or 'false' only.${NC}"
    fi
  done

  # Removed this hostnameparts question to avoid issues - .env can be manually edited if you have ACM and want a 3 part domain.
  #echo "Enter the number of parts in your hostname. For example, domain.com would be two parts ('domain' and 'com'), and sub.domain.com would be 3 parts ('sub', 'domain', and 'com')"
  #hostnameparts=$(get_input "Cloudflare free only supports two parts for wildcard domains without Advanced Certicate Manager(\$10/month):" "$HOSTNAME_PARTS" )
  #echo

  #if [[ $hostnameparts == 3 ]]; then
  #  echo -e "${YELLOW}⚠️ You are using a 3 part domain. Please ensure you have Advanced Certificate Manager enabled in Cloudflare.${NC}"
  #fi

  # Ask if Cloudflare origin certificates should be updated if they exist. Otherwise prompt if cert/key files are missing
  # This will create the cert/key in the current directory and append the domain name to the beginning of the file name
  if [[ -f "${domain}_origin_cert.pem" && -f "${domain}_origin_key.pem" ]]; then
    if [[ "$(get_input "❓ Update existing origin certificate and key? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      read -p "Press ENTER to open nano to paste the origin certificate. Ctrl+X, y, and ENTER to save."
      nano "${domain}_origin_cert.pem"
      read -p "Press ENTER to open nano to paste the origin private key. Ctrl+X, y, and ENTER to save."
      nano "${domain}_origin_key.pem"
    fi
  else
    # If origin cert missing
    if [[ ! -f "${domain}_origin_cert.pem" ]]; then
      echo -e "${YELLOW}⚠️ Origin certificate ${domain}_origin_cert.pem not found. Please paste it now.${NC}"
      read -p "Press ENTER to open nano to paste the origin certificate. Ctrl+X, y, and ENTER to save."
      nano "${domain}_origin_cert.pem"
    fi

    # If origin key missing
    if [[ ! -f "${domain}_origin_key.pem" ]]; then
      echo -e "${YELLOW}⚠️ Origin private key ${domain}_origin_key.pem not found. Please paste it now.${NC}"
      read -p "Press ENTER to open nano to paste the origin private key. Ctrl+X, y, and ENTER to save."
      nano "${domain}_origin_key.pem"
    fi
  fi
  # ====== END REQUIRED variables ======

  # ====== START OPTIONAL variables ======
  if [[ "$(get_input "❓ Update OPTIONAL variables? (y/n)" "n")" =~ ^[Yy]$ ]]; then
    read -p "🗺️ Enter your Google maps key: [$GOOGLE_MAPS_KEY]: " googlemapskey

    # Ask if analytics env variables should be set for PostHog, Google Analytics, or Mixpanel
    if [[ "$(get_input "❓ Update analytics variables? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      read -p "📊 Enter your PostHog key - https://posthog.com/: [$PUBLIC_POSTHOG_KEY]: " publicposthogkey
      read -p "📊 Enter your Google Analytics Measurement ID - https://analytics.google.com/: [$GA_TRACKING_ID]: " gatrackingid
      read -p "📊 Enter your Mixpanel key - https://mixpanel.com/: [$MIXPANEL_KEY]: " mixpanelkey
      read -p "📊 Enter your Microsoft Clarity code - https://clarity.microsoft.com/: [$CLARITY_PROJECT_ID]: " clarity_project_id
    fi

    # Ask if SOCIAL_META variable should be updated
    if [[ "$(get_input "❓ Update social meta tag? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      echo "See the RF docs for details on the SOCIAL_META tag:"
      echo -e "${BLUE}🔗 https://docs.remotefalcon.com/docs/developer-docs/running-it/digitalocean-droplet?#update-docker-composeyaml${NC}"
      echo
      echo "🏷️ Update SOCIAL_META tag or leave as default - Enter on one line only"
      echo
      read -p "[$SOCIAL_META]: " socialmeta
    fi

    # Ask if SEQUENCE_LIMIT variable should be updated
    while true; do
      sequencelimit=$(get_input "🎶 Enter desired sequence limit:" "$SEQUENCE_LIMIT")
      if [[ "$sequencelimit" =~ ^[1-9][0-9]*$ ]]; then
        break
      else
        echo -e "${RED}❌ Please enter a valid whole number greater than 0.${NC}"
      fi
    done

    # Ask if the user wants to switch the Viewer Page and Control Panel URLs
    if [[ -z "$SWAP_CP" || "$SWAP_CP" == false ]]; then
      if [[ "$(get_input "🔁 Would you like to swap the Control Panel and Viewer Page Subdomain URLs? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        swapCP=true
      fi
    else
      if [[ "$(get_input "🔁 Would you like to REVERT the Control Panel and Viewer Page Subdomain URLs back to the default? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        swapCP=false
      fi
    fi

    # If swapCP is set to true ask to update the Viewer Page Subdomain
    if [[ $swapCP == true ]]; then
      while true; do
        viewerPageSubdomain=$(get_input "🌐 Enter your Viewer Page Subdomain:" "$VIEWER_PAGE_SUBDOMAIN")

        # Remove all whitespace (leading, trailing, and internal)
        viewerPageSubdomain=$(echo "$viewerPageSubdomain" | tr -d '[:space:]')
        # Convert to lowercase
        viewerPageSubdomain=$(echo "$viewerPageSubdomain" | tr '[:upper:]' '[:lower:]')

        # Validate: only lowercase letters and digits
        if [[ -z "$viewerPageSubdomain" ]]; then
          echo -e "${RED}❌ Subdomain cannot be empty.${NC}"
        elif [[ "$viewerPageSubdomain" =~ [^a-z0-9] ]]; then
          echo -e "${RED}❌ Subdomain must contain only lowercase letters and numbers (no spaces, symbols, or hyphens).${NC}"
        else
          break
        fi
      done
    fi
  fi
  # Ensure optional variables are set to the current values regardless if they were updated or not
  repo=${repo:-$REPO}
  githubpat=${githubpat:-$GITHUB_PAT}
  hostnameparts=${hostnameparts:-$HOSTNAME_PARTS}
  googlemapskey=${googlemapskey:-$GOOGLE_MAPS_KEY}
  publicposthogkey=${publicposthogkey:-$PUBLIC_POSTHOG_KEY}
  gatrackingid=${gatrackingid:-$GA_TRACKING_ID}
  mixpanelkey=${mixpanelkey:-$MIXPANEL_KEY}
  clarity_project_id=${clarity_project_id:-$CLARITY_PROJECT_ID}
  socialmeta=${socialmeta:-$SOCIAL_META}
  sequencelimit=${sequencelimit:-$SEQUENCE_LIMIT}
  viewerPageSubdomain=${viewerPageSubdomain:-$VIEWER_PAGE_SUBDOMAIN}
  swapCP=${swapCP:-$SWAP_CP}
  # ====== END OPTIONAL variables ======

  # ====== START BUILD ARGs ======
  # Capture the current values of any BUILD args(from sourced .env) that weren't asked for above
  version=${version:-$VERSION}
  hostenv=${hostenv:-$HOST_ENV}
  publicposthoghost=${publicposthoghost:-$PUBLIC_POSTHOG_HOST}
  otelopts=${otelopts:-$OTEL_OPTS}
  oteluri=${oteluri:-$OTEL_URI}
  mongouri=${mongouri:-$MONGO_URI}

  # ====== START Automatically configured variables ======
  # Check VIEWER_JWT_KEY and USER_JWT_KEY .env variables and generate a random Base64 value if set to default 123456
  if [[ $VIEWER_JWT_KEY == "123456" ]]; then
    VIEWER_JWT_KEY=$(openssl rand -base64 32)
    sed -i "s|^VIEWER_JWT_KEY=.*|VIEWER_JWT_KEY=$VIEWER_JWT_KEY|" "$ENV_FILE"
  fi
  if [[ $USER_JWT_KEY == "123456" ]]; then
    USER_JWT_KEY=$(openssl rand -base64 32)
    sed -i "s|^USER_JWT_KEY=.*|USER_JWT_KEY=$USER_JWT_KEY|" "$ENV_FILE"
  fi
  # ====== END Automatically configured variables ======

  # ====== END variable questions ======

  # ====== START Existing configuration ======
  # This section checks if any containers are running and ensures that compose.yaml tags match currently running versions(if in valid format)

  # Check if containers are running, meaning this is an existing configuration
  for service in "${SERVICES[@]}"; do
    if is_container_running "$service"; then
      ANY_SERVICE_RUNNING=true
      current_version=$(get_current_version "$service")
      compose_tag=$(get_current_compose_tag "$service")

      # Compare running container tags to the compose.yaml tags and update compose.yaml if compose tag is
      # Check if the running container's tag is in the valid format
      if check_tag_format "$service" "$current_version"; then
        # If the compose tag does not match the current running version, update the compose tag in compose.yaml - this is useful if compose.yaml was replaced and all are tagged to 'latest'
        if [[ "$compose_tag" != "$current_version" ]]; then
          echo -e "${BLUE}⚠️ $service ${YELLOW}is running with version ${GREEN}$current_version${YELLOW} but the compose tag 🏷️ ${GREEN}$compose_tag${NC}${YELLOW} does not match. Updating compose tag to match...${NC}"
          replace_compose_tag "$service" "$current_version"
          echo -e "✔  ${BLUE}$service ${NC}compose tag updated to ${GREEN}$current_version.${NC}"
        fi
      fi
    fi
  done

  # ====== END Existing configuration ======

  # Run the container update scripts if .env variables were 'changed' and 'accepted'
  if update_env; then
    # From shared_function.sh, make sure the compose.yaml is set for pulling images via ghcr.io/${REPO}/ in the image path or set for local build
    update_compose_image_path

    # Update handling if any container is running
    if [[ $ANY_SERVICE_RUNNING == true ]]; then
      # Only rebuild images if the build ARGs were changed
      if [[ $image_rebuild_needed = true ]]; then
        # If any service is running and $REPO is configured run run_workflow.sh to rebuild all containers with any updated ARG values from the .env file
        if [[ -n "$REPO" && "$REPO" != "username/repo" ]]; then
          echo -e "${YELLOW}⚠️ Containers are running. Build ARG changes detected. Running ./run_workflow.sh to ensure Remote Falcon images are built with any updated build ARGs at their current version...${NC}"
          # Run the workflow script to rebuild all containers with any updated ARG values from the .env file, images are built based on current short_sha tag in compose.yaml
          if bash "$SCRIPT_DIR/run_workflow.sh" \
            plugins-api=$(get_current_version "plugins-api") \
            control-panel=$(get_current_version "control-panel") \
            viewer=$(get_current_version "viewer") \
            ui=$(get_current_version "ui") \
            external-api=$(get_current_version "external-api"); then
              echo -e "${GREEN}🚀 Bringing up containers...${NC}"
              sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate
          else
              echo -e "${RED}❌ Workflow to build all Remote Falcon images to current versions did not complete successfully, aborting.${NC}"
              exit 1
          fi
        else # If any service is running and $REPO is not configured, build locally
          echo -e "${YELLOW}⚠️ Containers are running. Build ARG changes detected. Running 'sudo docker compose up -d --build --force-recreate' to apply any ARG and .env changes...${NC}"
          sudo docker compose -f "$COMPOSE_FILE" up -d --build --force-recreate
        fi
      else # No ARGs changed, just run 'sudo docker compose up -d' to pick up any environment variable changes
          echo -e "${YELLOW}⚠️ Containers are running. No build ARG changes detected. Running 'sudo docker compose up -d' to apply any environmental variable changes...${NC}"
          sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate
      fi

      # Prompt to check updates after applying new .env values to existing containers
      if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        run_updates
      elif [[ "$(get_input "❓ Run health check script? (y/n)" "y")" =~ ^[Yy]$ ]]; then
        health_check health
      fi
    else # No containers running
      echo -e "No containers are running. Checking Remote Falcon image tags for 'latest' in compose.yaml..."
      # No containers running, only rebuild images if the build ARGs were changed
      if [[ $image_rebuild_needed = true ]]; then
        echo -e "${YELLOW}⚠️ Remote Falcon image build required...${NC}"
        if [[ -n "$REPO" && "$REPO" != "username/repo" ]]; then
          echo -e "🐙 GitHub repository ${REPO} will be used for the build.${NC}"
          if tag_has_latest; then
            # No containers running, REPO configured, rebuild required, RF containers tagged to 'latest' Assume new install, run workflow to build latest images and run_updates auto-apply
            echo -e "${BLUE}✨ Remote Falcon 'latest' image tags detected in compose.yaml, assuming new install. Running ./run_workflow.sh to build new Remote Falcon images on GitHub....${NC}"
            if bash "$SCRIPT_DIR/run_workflow.sh"; then
              run_updates auto-apply
            else
              echo -e "${RED}❌ Workflow failed. Aborting.${NC}"
              exit 1
            fi
          else # No containers running, REPO configured, rebuild required, and RF containers not tagged to 'latest' so we just rebuild with existing image tags from compose.yaml
            echo -e "${BLUE}🔄 Running ./run_workflow.sh to ensure Remote Falcon images are built with any updated build ARGs at their current version...${NC}"
            if bash "$SCRIPT_DIR/run_workflow.sh" \
              plugins-api=$(get_current_compose_tag "plugins-api") \
              control-panel=$(get_current_compose_tag "control-panel") \
              viewer=$(get_current_compose_tag "viewer") \
              ui=$(get_current_compose_tag "ui") \
              external-api=$(get_current_compose_tag "external-api"); then
                echo -e "${GREEN}🚀 Bringing up containers...${NC}"
                sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate
            else
              echo -e "${RED}❌ Workflow failed. Aborting.${NC}"
              exit 1
            fi
          fi
        else # No containers running, REPO not configured so images will be built locally
          echo -e "${YELLOW}⚠️ GitHub Repository not configured, Remote Falcon images will be built locally, ensure that you have 16GB+ RAM or the build may fail...${NC}"

          if tag_has_latest; then
            echo -e "${BLUE}✨ Remote Falcon 'latest' image tags detected in compose.yaml, assuming new install, running update_containers.sh...${NC}"
            run_updates auto-apply
          else # Assume existing install since no 'latest' tags found, force local build and restart
            echo -e "${BLUE}🔄 Building Remote Falcon images to apply any updated build ARGs at their current version...${NC}"
            sudo docker compose up -d --build --force-recreate
          fi
        fi
      else # No containers running, image rebuild not required(ARGs weren't changed in script)
        if tag_has_latest; then
          # Run run_updates auto-apply to tag containers
          echo -e "${GREEN}🚀 Bringing up existing containers to apply any .env changes...${NC}"
          run_updates auto-apply
        else # No containers running, no image rebuild required, and no 'latest' tags found so just bring the containers up
          # Run interactive updates since update_containers will verify if the image exists in the repo and build indvidually if missing
          if [[ -n "$REPO" && "$REPO" != "username/repo" ]]; then
            echo -e "${GREEN}🚀 Bringing up stopped containers with update_container.sh...${NC}"
            run_updates
          else # No containers running, no image rebuild required, so just bring the containers up
            echo -e "${GREEN}🚀 Bringing up existing containers to apply any .env changes...${NC}"
            sudo docker compose up -d
          fi
        fi
      fi
    fi
  else # update_env returned false - Ask to run update check anyway
    if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      run_updates
    elif [[ "$(get_input "❓ Run health check script? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      health_check health
    fi
  fi
else # User chose not to update the .env file
  echo -e "${YELLOW}⚠️ No .env variables modified.${NC}"
  if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
    run_updates
  elif [[ "$(get_input "❓ Run health check script? (y/n)" "n")" =~ ^[Yy]$ ]]; then
    health_check health
  fi
fi

echo -e "${GREEN}🎉 Done! Exiting ${RED}RF${NC}${GREEN} configuration script...${NC}"
exit 0
