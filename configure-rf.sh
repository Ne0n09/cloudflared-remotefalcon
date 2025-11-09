#!/bin/bash

# VERSION=2025.11.8.1

#set -euo pipefail

# ./configure-rf.sh [-y|--non-interactive] [--update-all|--update-scripts|--update-files|--update-workflows|--no-updates] [--set KEY=VALUE ...]

NON_INTERACTIVE=false
UPDATE_MODES=()
DEBUG_INPUT=false # Used to debug input parsing when running in NON_INTERACTIVE mode

declare -A OVERRIDES=()

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --update-all)
      UPDATE_MODES=("all")
      shift
      ;;
    --update-scripts)
      UPDATE_MODES=("scripts")
      shift
      ;;
    --update-files)
      UPDATE_MODES=("files")
      shift
      ;;
    --update-workflows)
      UPDATE_MODES=("workflows")
      shift
      ;;
    --no-updates)
      UPDATE_MODES="none"
      shift
      ;;
    --set)
      # support: --set KEY=VALUE  (argument form)
      if [[ -n "${2-}" && "${2}" == *=* ]]; then
        kv="$2"
        shift 2
      else
        echo "Error: --set requires KEY=VALUE" >&2
        exit 2
      fi
      key="${kv%%=*}"
      val="${kv#*=}"
      OVERRIDES["$key"]="$val"
      ;;
    --set=*)
      # support: --set=KEY=VALUE  (equals form)
      kv="${1#--set=}"
      shift
      key="${kv%%=*}"
      val="${kv#*=}"
      OVERRIDES["$key"]="$val"
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo
      echo "Options:"
      echo "  -y|--non-interactive      Run non-interactively (no prompts)"
      echo "  --update-all              Update scripts, files, and workflows"
      echo "  --update-scripts          Update only scripts"
      echo "  --update-files            Update only compose.yaml, .env, and default.conf files"
      echo "  --update-workflows        Update only image builder GitHub workflows"
      echo "  --set KEY=VALUE           Set configuration override for config questions(can be used multiple times)"
      echo "  -h, --help                Show this help message"
      exit 0
      ;;
      *)
      # unknown argument — keep or handle as you need
      # If you want to pass-through remaining args to other tools, break
      # break
      echo "Unknown option: $1" >&2
      shift
      ;;
  esac
done

if [ "${DEBUG_INPUT:-false}" = true ] ; then
  echo "--------------------------------------------"
  echo "⚙️  Arg Parse Debug (stderr):"
  echo "  NON_INTERACTIVE=$NON_INTERACTIVE" >&2
  for k in "${!OVERRIDES[@]}"; do
    echo "  OVERRIDE: $k=${OVERRIDES[$k]}" >&2
  done
  echo "--------------------------------------------" >&2
fi

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
SETUP_CLOUDFLARE_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/setup_cloudflare.sh"
SERVICES=(external-api ui plugins-api viewer control-panel cloudflared nginx mongo minio)
ANY_SERVICE_RUNNING=false
TEMPLATE_REPO="Ne0n09/remote-falcon-image-builder" # Template repo for image builder workflows

# new_build_args array to track if any build args changed that would require RF container rebuild
# For GHCR builds these get synced with sync_repo_secrets.sh
# "CONTROL_PANEL_API" "VIEWER_API" not included because we only want to track if DOMAIN is changed
#### This will need to be updated down in update_env() if any new build context args are added - sync_repo_secrets will also need to be updated

# Function to check update arguments
check_update_modes() {
  local type="$1"

  # If "all" is requested, always run
  for mode in "${UPDATE_MODES[@]}"; do
    if [ "$mode" = "all" ]; then
      return 0
    elif [ "$mode" = "$type" ]; then
      return 0
    elif [ "$mode" = "none" ]; then
      return 1
    fi
  done

  # Default: nothing requested, run everything
  if [ "${#UPDATE_MODES[@]}" -eq 0 ]; then
    return 0
  fi

  return 1
}

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
download_file $SETUP_CLOUDFLARE_URL "setup_cloudflare.sh"
download_file $RUN_WORKFLOW_URL "run_workflow.sh"
download_file $SYNC_REPO_SECRETS_URL "sync_repo_secrets.sh"
chmod +x "shared_functions.sh" "update_containers.sh" "health_check.sh" "minio_init.sh" "setup_cloudflare.sh" "run_workflow.sh" "sync_repo_secrets.sh"

## Check for script updates
BASE_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main"

# Mapping of files to their version tag patterns
declare -A FILES=(
  [shared_functions.sh]="SHARED_FUNCTIONS_VERSION="
  [configure-rf.sh]="VERSION="
  [update_containers.sh]="VERSION="
  [health_check.sh]="VERSION="
  [sync_repo_secrets.sh]="VERSION="
  [minio_init.sh]="VERSION="
  [setup_cloudflare.sh]="VERSION="
  [run_workflow.sh]="VERSION="
  [compose.yaml]="COMPOSE_VERSION="
  [.env]="ENV_VERSION="
  [default.conf]="VERSION="
)

echo -e "${BLUE}🔗 https://ne0n09.github.io/cloudflared-remotefalcon/release-notes/${NC}"

# Base function to check for updates and prompt user to update
check_updates() {
  local title="$1"         # e.g. "📜 Checking for script updates..."
  local type_name="$2"     # e.g. "scripts" or "files"
  local dir="$3"           # local directory
  local remote_path="$4"   # remote URL path (can be "" or "remotefalcon")
  shift 4
  local files=("$@")       # file list

  echo -e "${CYAN}${title}${NC}"

  local outdated=()

  printf "%-25s %-15s %-15s %-7s\n" "File" "Local Version" "Remote Version" "Status"
  printf "${YELLOW}%-25s %-15s %-15s %-7s${NC}\n" "─────────────────────────" "───────────────" "───────────────" "───────"

  for file in "${files[@]}"; do
    pattern="${FILES[$file]}"
    local_file="$dir/$file"
    local_ver="N/A"

    if [[ -f "$local_file" ]]; then
      local_ver=$(grep -Eo "^# ${pattern}[0-9.]+" "$local_file" | head -n1 | sed -E "s/^# ${pattern}//" | tr -d '\r')
    fi

    local full_url="$BASE_URL"
    [[ -n "$remote_path" ]] && full_url="${full_url}/${remote_path}"
    remote_ver=$(curl -fsSL "${full_url}/${file}" 2>/dev/null | grep -Eo "^# ${pattern}[0-9.]+" | head -n1 | sed -E "s/^# ${pattern}//" | tr -d '\r')

    if [[ -z "$remote_ver" ]]; then
      status="⚠️ Skipped"
    elif [[ "$local_ver" == "$remote_ver" ]]; then
      status="${GREEN}✅ OK${NC}"
    else
      status="${YELLOW}🔄 Update${NC}"
      outdated+=("$file")
    fi

    printf "🔸 %-23s %-15s %-15s %-7b\n" "$file" "$local_ver" "$remote_ver" "$status"
  done

  printf "${YELLOW}%-25s %-15s %-15s %-7s${NC}\n" "─────────────────────────" "───────────────" "───────────────" "───────"

  if [[ ${#outdated[@]} -eq 0 ]]; then
    echo -e "${GREEN}✅ All ${type_name} are up to date!${NC}"
    UPDATED_FILES=()
    return
  fi

  if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
    ans="y"
  else
    read -rp "❓ Would you like to update all outdated ${type_name} now? (y/n) [n]: " ans
  fi
  [[ ! "$ans" =~ ^[Yy]$ ]] && echo -e "⏭️ Skipped ${type_name} updates." && UPDATED_FILES=() && return

  echo -e "⬇️ Updating outdated ${type_name}..."
  UPDATED_FILES=("${outdated[@]}")
}

# Function to display and check for updates to the helper scripts with a prompt to upddate all that are out of date
update_scripts() {
  if ! check_update_modes "scripts"; then
    echo -e "${YELLOW}⚠️ Skipping script updates.${NC}"
    return
  fi
  local files=(shared_functions.sh update_containers.sh health_check.sh sync_repo_secrets.sh minio_init.sh setup_cloudflare.sh run_workflow.sh configure-rf.sh)
  check_updates "📜 Checking for script updates..." "scripts" "$SCRIPT_DIR" "" "${files[@]}"

  # If user accepted updates
  for file in "${UPDATED_FILES[@]}"; do
    local_file="$SCRIPT_DIR/$file"
    echo -e "→ Updating $file..."
    backup_file "$local_file"
    curl -fsSL "$BASE_URL/$file" -o "$local_file"
    chmod +x "$local_file"

    new_ver=$(grep -Eo "^# ${FILES[$file]}[0-9.]+" "$local_file" | head -n1 | sed -E "s/^# ${FILES[$file]}//" | tr -d '\r')
    echo -e "${GREEN}✅ $file updated to version ${YELLOW}$new_ver${NC}"

    # Special case: restart if configure-rf.sh updated
    if [[ "$file" == "configure-rf.sh" ]]; then
      echo -e "${BLUE}🔁 Restarting script to load new version...${NC}"
      exec "$SCRIPT_DIR/configure-rf.sh" "$@"
    fi
  done
}

# Function to display and check for updates to the compose, .env, and default.conf files with a prompt to upddate all that are out of date
update_files() {
  if ! check_update_modes "files"; then
    echo -e "${YELLOW}⚠️ Skipping file updates.${NC}"
    return
  fi
  local files=(compose.yaml .env default.conf)
  check_updates "🧩 Checking for file updates..." "files" "$WORKING_DIR" "remotefalcon" "${files[@]}"

  for file in "${UPDATED_FILES[@]}"; do
    local_file="$WORKING_DIR/$file"
    echo -e "→ Updating $file..."
    backup_file "$local_file"

    # --- Special handling for compose.yaml ---
    if [[ "$file" == "compose.yaml" && -f "$local_file" ]]; then
      echo -e "${CYAN}🗂️ Capturing image and context lines...${NC}"

      declare -A OLD_IMAGES
      declare -A OLD_CONTEXTS

      # Capture image lines (full lines)
      while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*image:[[:space:]]*.+$ ]]; then
          # Extract potential service name
          image_value=$(echo "$line" | sed -E 's/^[[:space:]]*image:[[:space:]]*//')
          if [[ "$image_value" == */* ]]; then
            # ghcr.io/.../service:tag → extract "service"
            service=$(echo "$image_value" | sed -E 's|.*/([^:/]+):.*|\1|')
          else
            # image: nginx:1.29.2 → extract "nginx"
            service=$(echo "$image_value" | sed -E 's|^([^:]+):.*|\1|')
          fi

          # Trim any stray whitespace
          service=$(echo "$service" | xargs)
          OLD_IMAGES["$service"]="$line"
          #echo "Captured image line for service '$service': ${line}"
        fi
      done < "$local_file"

      # Capture context lines
      while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*context:[[:space:]]*https://github.com/Remote-Falcon/remote-falcon-([a-zA-Z0-9_-]+)\.git ]]; then
          service="${BASH_REMATCH[1]}"
          OLD_CONTEXTS["$service"]="$line"
          #echo "Captured context line for service '$service': ${line}"
        fi
      done < "$local_file"

      echo -e "${CYAN}⬇️ Downloading new compose.yaml...${NC}"
      curl -fsSL "$BASE_URL/remotefalcon/$file" -o "$local_file"
      new_ver=$(grep -Eo "^# ${FILES[$file]}[0-9.]+" "$local_file" | head -n1 | sed -E "s/^# ${FILES[$file]}//" | tr -d '\r')

      echo -e "${CYAN}♻️ Restoring captured image and context lines...${NC}"

      # Restore contexts
      for service in "${!OLD_CONTEXTS[@]}"; do
        old_line="${OLD_CONTEXTS[$service]}"
        if [[ -n "$old_line" ]]; then
          #echo "Restoring context for service '${service}'"
          # Replace the matching context line for this service
          sed -i -E "s|^[[:space:]]*context:[[:space:]]*https://github.com/Remote-Falcon/remote-falcon-${service}\.git.*|${old_line}|" "$local_file"
        fi
      done

      # Restore image lines
      for service in "${!OLD_IMAGES[@]}"; do
        old_line="${OLD_IMAGES[$service]}"
        if [[ -n "$old_line" ]]; then
          #echo "Restoring image line for service '${service}'"
          # Replace image line that references this service
          sed -i -E "s|^[[:space:]]*image:[[:space:]]*.*${service}.*|${old_line}|" "$local_file"
        fi
      done

      echo -e "${GREEN}✅ compose.yaml updated to version ${YELLOW}$new_ver${NC} and previous image and context lines restored.${NC}"
      continue
    fi

    # --- Special handling for .env updates ---
    if [[ "$file" == ".env" && -f "$local_file" ]]; then
      echo -e "${CYAN}🗂️ Capturing current .env values...${NC}"

      declare -A OLD_ENV

      while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Extract key (before first '=') and value (everything after)
        key="${line%%=*}"
        value="${line#*=}"

        # Trim whitespace (optional)
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        # Skip ENV_VERSION
        [[ "$key" == "ENV_VERSION" ]] && continue

        OLD_ENV["$key"]="$value"
      done < "$local_file"

      echo -e "${CYAN}⬇️ Downloading new .env...${NC}"
      curl -fsSL "$BASE_URL/remotefalcon/$file" -o "$local_file"
      new_ver=$(grep -Eo "^# ${FILES[$file]}[0-9.]+" "$local_file" | head -n1 | sed -E "s/^# ${FILES[$file]}//" | tr -d '\r')

      echo -e "${CYAN}♻️ Restoring previous .env values...${NC}"

      # Restore matching keys in the new file
      for key in "${!OLD_ENV[@]}"; do
        old_value="${OLD_ENV[$key]}"
        if grep -qE "^${key}=" "$local_file"; then
          sed -i -E "s|^${key}=.*|${key}=${old_value}|" "$local_file"
          #echo "Restored: ${key}=${old_value}"
        fi
      done

      echo -e "${GREEN}✅ .env updated to version ${YELLOW}$new_ver${NC} and previous values restored.${NC}"
      continue
    fi

    # --- Default file update ---
    curl -fsSL "$BASE_URL/remotefalcon/$file" -o "$local_file"
    new_ver=$(grep -Eo "^# ${FILES[$file]}[0-9.]+" "$local_file" | head -n1 | sed -E "s/^# ${FILES[$file]}//" | tr -d '\r')
    echo -e "${GREEN}✅ $file updated to version ${YELLOW}$new_ver${NC}"
  done
}

update_scripts

# Function to check for updates to the image builder workflows if REPO is configured.
check_image_builder_updates() {
  if ! check_update_modes "workflows"; then
    echo -e "${YELLOW}⚠️ Skipping image builder workflow updates.${NC}"
    return
  fi
  # Check if .env file exists before proceeding
  if [[ ! -f $ENV_FILE ]]; then
    return
  fi

  REPO=$(grep -E '^REPO=' $ENV_FILE | cut -d '=' -f2- | tr -d '\r')
  GITHUB_PAT=$(grep -E '^GITHUB_PAT=' $ENV_FILE | cut -d '=' -f2- | tr -d '\r')

  if [[ -z "$REPO" || "$repo" == "username/repo" || -z "$GITHUB_PAT" ]]; then
    return
  fi

  TEMPLATE_URL_BASE="https://raw.githubusercontent.com/Ne0n09/remote-falcon-image-builder/main/.github/workflows"
  PRIVATE_URL_BASE="https://raw.githubusercontent.com/${REPO}/main/.github/workflows"
  WORKFLOW_DIR=".github/workflows"
  WORKFLOW_FILES=("build-all.yml" "build-container.yml")
  echo -e "${CYAN}📜 Checking for image builder workflow updates...${NC}"
  printf "%-25s %-15s %-15s %-7s\n" "Workflow" "Your Version" "Template Version" "Status"
  printf "${YELLOW}%-25s %-15s %-15s %-7s${NC}\n" "─────────────────────────" "───────────────" "───────────────" "───────"

  outdated=()

  for file in "${WORKFLOW_FILES[@]}"; do
    # Get versions from template (remote) and private (local)
    remote_ver=$(curl -fsSL "$TEMPLATE_URL_BASE/$file" | grep -Eo "^# VERSION=[0-9.]+" | sed -E 's/^# VERSION=//')
    local_ver=$(curl -fsSL -H "Authorization: token $GITHUB_PAT" "$PRIVATE_URL_BASE/$file" | grep -Eo "^# VERSION=[0-9.]+" | sed -E 's/^# VERSION=//')

    if [[ -z "$remote_ver" ]]; then
      status="⚠️ Skipped"
    elif [[ "$local_ver" == "$remote_ver" ]]; then
      status="${GREEN}✅ OK${NC}"
    elif [[ -z "$local_ver" ]]; then
      status="${YELLOW}🆕 Missing${NC}"
      outdated+=("$file")
    else
      status="${YELLOW}🔄 Update${NC}"
      outdated+=("$file")
    fi

    printf "🔸 %-23s %-15s %-15s %-7b\n" "$file" "${local_ver:-N/A}" "${remote_ver:-N/A}" "$status"
  done

  printf "${YELLOW}%-25s %-15s %-15s %-7s${NC}\n" "─────────────────────────" "───────────────" "───────────────" "───────"

 # --- Prompt for updates ---
  if (( ${#outdated[@]} > 0 )); then
    echo -e "${BLUE}🔗 https://github.com/Ne0n09/remote-falcon-image-builder/${NC}"

    if [[ "$(get_input "❓ Would you like to update all image builder workflows now? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      TMP_DIR=$(mktemp -d)
      echo -e "${CYAN}⬇️ Downloading updates to temporary directory...${NC}"
      for file in "${outdated[@]}"; do
        curl -fsSL "$TEMPLATE_URL_BASE/$file" -o "$TMP_DIR/$file"
      done

      echo -e "${CYAN}⬆️ Updating files in private repository...${NC}"

      git config --global user.name "GitHub Actions"
      git config --global user.email "actions@github.com"

      # Clone private repo using GITHUB_PAT
      echo -e "${CYAN}🔍 Cloning ${REPO}...${NC}"
      git clone "https://${GITHUB_PAT}@github.com/${REPO}.git" repo_tmp
      cd repo_tmp || return

      # Detect branch dynamically
      current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
      echo -e "${CYAN}🌿 Detected branch:${NC} ${YELLOW}${current_branch}${NC}"

      mkdir -p "$WORKFLOW_DIR"
      for file in "${outdated[@]}"; do
        cp "$TMP_DIR/$file" "$WORKFLOW_DIR/$file"
        echo -e "${GREEN}✔ Updated:${NC} $file"
      done

      echo -e "${CYAN}📦 Staging changes...${NC}"
      git add "$WORKFLOW_DIR"

      echo -e "${CYAN}📝 Committing changes...${NC}"
      git commit -m "🔄 Update image builder workflows"

      echo -e "${CYAN}🚀 Pushing to branch:${NC} ${YELLOW}${current_branch}${NC}"
      git push origin "$current_branch"

      cd ..
      rm -rf repo_tmp "$TMP_DIR"

      echo -e "${GREEN}✅ Image builder workflows updated and pushed to ${CYAN}${REPO}:${current_branch}${NC}.${NC}"
    else
      echo -e "${CYAN}ℹ️  Skipped updating workflows.${NC}"
    fi
  else
    echo -e "${GREEN}✅ All image builder workflows are up to date.${NC}"
  fi
}

check_image_builder_updates

# Function to get user input for configuration questions in the format of get_input KEY PROMPT DEFAULT
get_input() {
  local key=""
  local prompt=""
  local default=""
  local input=""

  # Accept DEBUG_INPUT values like "true" (string)
  local debug="${DEBUG_INPUT:-false}"

  # Detect args
  if [ $# -eq 3 ]; then
    key="$1"; prompt="$2"; default="$3"
  elif [ $# -eq 2 ]; then
    key=""; prompt="$1"; default="$2"
  else
    printf '%s\n' "get_input: invalid number of arguments" >&2
    return 1
  fi

  if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
    if [ -n "$key" ] && [ -n "${OVERRIDES[$key]+set}" ]; then
      input="${OVERRIDES[$key]}"
    else
      # Auto-yes logic for yes/no prompts in non-interactive mode
      if [[ "$prompt" =~ \(\s*[Yy]\/[Nn]\s*\) ]] && [[ "$default" =~ ^[Nn]$ ]]; then
        input="y"
      else
        input="$default"
      fi
    fi

    # Log automated input to console
    printf '%s\n' "⚙️: $prompt [$default]: $input" >&2

    printf '%s' "$input"
    return 0
  fi

  # Interactive mode: prompt the user, keep any prompt output on stdout
  read -rp "$prompt [$default]: " input
  printf '%s' "${input:-$default}"
}

# Function to update the the .env file with required variables to run RF and some optional variables
update_env() {
  pending_changes=false # This is to track if any .env values would change
  pending_arg_changes=false # This is to track if any BUILD args would change

  # Declare NEW variables to check against existing .env values to detect if anything changed
  declare -A new_env_vars=(
    ["REPO"]="$REPO"
    ["TUNNEL_TOKEN"]="$TUNNEL_TOKEN"
    ["DOMAIN"]="$DOMAIN"
#    ["HOSTNAME_PARTS"]="$HOSTNAME_PARTS"
    ["AUTO_VALIDATE_EMAIL"]="$AUTO_VALIDATE_EMAIL"
    ["NGINX_CERT"]="./${DOMAIN}_origin_cert.pem"
    ["NGINX_KEY"]="./${DOMAIN}_origin_key.pem"
    ["GOOGLE_MAPS_KEY"]="$GOOGLE_MAPS_KEY"
    ["PUBLIC_POSTHOG_KEY"]="$PUBLIC_POSTHOG_KEY"
    ["GA_TRACKING_ID"]="$GA_TRACKING_ID"
    ["MIXPANEL_KEY"]="$MIXPANEL_KEY"
#    ["CLIENT_HEADER"]="$CLIENT_HEADER"
#    ["SENDGRID_KEY"]="$SENDGRID_KEY"
    ["GITHUB_PAT"]="$GITHUB_PAT"
    ["SOCIAL_META"]="$SOCIAL_META"
    ["SEQUENCE_LIMIT"]="$SEQUENCE_LIMIT"
    ["SWAP_CP"]="$SWAP_CP"
    ["VIEWER_PAGE_SUBDOMAIN"]="$VIEWER_PAGE_SUBDOMAIN"
    ["CLARITY_PROJECT_ID"]="$CLARITY_PROJECT_ID"
  )

  # If any of these are changed, an image rebuild will be required.
  declare -A new_build_args=(
    ["VERSION"]="$VERSION"
    ["HOST_ENV"]="$HOST_ENV"
    ["DOMAIN"]="$DOMAIN"
    ["GOOGLE_MAPS_KEY"]="$GOOGLE_MAPS_KEY"
    ["PUBLIC_POSTHOG_KEY"]="$PUBLIC_POSTHOG_KEY"
    ["PUBLIC_POSTHOG_HOST"]="$PUBLIC_POSTHOG_HOST"
    ["GA_TRACKING_ID"]="$GA_TRACKING_ID"
    ["MIXPANEL_KEY"]="$MIXPANEL_KEY"
    ["HOSTNAME_PARTS"]="$HOSTNAME_PARTS"
    ["SOCIAL_META"]="$SOCIAL_META"
    ["SWAP_CP"]="$SWAP_CP"
    ["VIEWER_PAGE_SUBDOMAIN"]="$VIEWER_PAGE_SUBDOMAIN"
    ["OTEL_OPTS"]="$OTEL_OPTS"
    ["OTEL_URI"]="$OTEL_URI"
    ["MONGO_URI"]="$MONGO_URI"
    ["CLARITY_PROJECT_ID"]="$CLARITY_PROJECT_ID"
  )

# Compare new_env_vars to existing_env_vars
  for key in "${!new_env_vars[@]}"; do
    local current_val="${existing_env_vars[$key]}"
    local new_val="${new_env_vars[$key]}"

    if [[ "$new_val" != "$current_val" ]]; then
      pending_changes=true
      break
    fi
  done

  if tag_has_latest; then # With the setup_cloudflare script it will populate some initial arg values so assume build is needed if tags are set to latest
    pending_arg_changes=true
  else
    for key in "${!new_build_args[@]}"; do
      local current_val="${existing_env_vars[$key]}"
      local new_val="${new_build_args[$key]}"

      if [[ "$new_val" != "$current_val" ]]; then
        pending_arg_changes=true
        break
      fi
    done
  fi

  if [ "$pending_changes" = false ]; then
    echo -e "${YELLOW}⚠️ No changes detected — skipping .env update prompt.${NC}"
    return 1
  else
    # Print all answers before asking to update the .env file
    echo
    echo -e "${YELLOW}⚠️ Please confirm the values below are correct:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    # Iterate over the original order of keys
    for key in "${original_keys[@]}"; do
      if [[ -v new_env_vars[$key] ]]; then  # Ensures empty values are displayed
        echo -e "${BLUE}🔸 $key${NC}=${YELLOW}${new_env_vars[$key]}${NC}"
      fi
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ "$pending_arg_changes" = true ]; then
      echo
      if ! tag_has_latest; then
        echo -e "${YELLOW}⚠️ The following build arguments have changed. Remote Falcon container images will need to be (re)built for the changes to take effect:${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        for key in "${original_keys[@]}"; do
          if [[ -v new_build_args[$key] ]]; then
            current_val=$(grep -E "^${key}=" .env | cut -d'=' -f2-)
            if [[ "${new_build_args[$key]}" != "$current_val" ]]; then
              echo -e "${RED}🔧 $key${NC}=${YELLOW}${new_build_args[$key]}${NC}"
            fi
          fi
        done
      fi
      echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
  fi

  # Validate the variables before writing to .env
  echo -e "${CYAN}🔍 Validating variables: ${vars_to_validate[*]}${NC}"

  vars_to_validate=(TUNNEL_TOKEN DOMAIN AUTO_VALIDATE_EMAIL HOSTNAME_PARTS SEQUENCE_LIMIT SWAP_CP VIEWER_PAGE_SUBDOMAIN)

  # Run validation
  if ! validate_variables "${vars_to_validate[@]}"; then
    echo -e "${RED}❌ Validation failed. .env file was not updated.${NC}"
    return 1
  else
    echo -e "${GREEN}✅ All environment variables validated successfully.${NC}"
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

# Function to validate variable input and display a mesage if invalid.
validate_variables() {
  local valid=true

  if [[ "$DEBUG_INPUT" == "true" ]]; then
    echo -e "${CYAN}DEBUG: validate_variables called with args: $@${NC}" >&2
  fi

  while (( "$#" )); do
    local var_name="$1"
    local test_value=""
    shift

    # Check if next argument is a *direct value*, not a variable name
    if (( $# )) && [[ ! "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      test_value="$1"
      shift
    else
      # If not provided, use indirect expansion
      test_value="${!var_name:-}"
    fi

    case "$var_name" in
      TUNNEL_TOKEN)
        if [[ -z "$test_value" || "$test_value" == "cloudflare_token" ]]; then
          echo -e "${RED}❌ $var_name is missing or placeholder (value: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      DOMAIN)
        if [[ -z "$test_value" || "$test_value" == "your_domain.com" ]]; then
          echo -e "${RED}❌ $var_name is invalid or placeholder (value: '${test_value:-empty}').${NC}" >&2
          valid=false
        elif [[ ! "$test_value" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
          echo -e "${RED}❌ $var_name ('$test_value') is not a valid domain format (yourdomain.com).${NC}" >&2
          valid=false
        fi
        ;;
      AUTO_VALIDATE_EMAIL)
        test_value="${test_value,,}" # Convert to lower case
        if [[ "$test_value" != "true" && "$test_value" != "false" ]]; then
          echo -e "${RED}❌ $var_name must be 'true' or 'false' (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      HOSTNAME_PARTS)
        if [[ ! "$test_value" =~ ^[23]$ ]]; then
          echo -e "${RED}❌ $var_name must be 2 or 3 (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      GITHUB_PAT)
#        if [[ -z "$test_value" ]]; then
#          echo -e "${RED}❌ GitHub Personal Access Token cannot be blank.${NC}" >&2
#          valid=false
        if [[ -n "$test_value" ]] && [[ ! "$test_value" =~ ^[0-9a-f]{40}$ ]] && [[ ! "$test_value" =~ ^gh[pousr]_[A-Za-z0-9_]{36,255}$ ]]; then
          echo -e "${RED}❌ GitHub Personal Access Token is not in the correct format (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      SEQUENCE_LIMIT)
        if [[ ! "$test_value" =~ ^[1-9][0-9]*$ ]]; then
          echo -e "${RED}❌ Please enter a valid whole number greater than 0 (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      SWAP_CP)
        test_value="${test_value,,}" # Convert to lower case
        if [[ "$test_value" != "true" && "$test_value" != "false" ]]; then
          echo -e "${RED}❌ $var_name must be 'true' or 'false' (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      VIEWER_PAGE_SUBDOMAIN)
        if [[ $SWAP_CP == "true" ]]; then
          # Validate: only lowercase letters and digits
          test_value=$(echo "$test_value" | tr -d '[:space:]')
          test_value=$(echo "$test_value" | tr '[:upper:]' '[:lower:]')
          if [[ -z "$test_value" ]]; then
            echo -e "${RED}❌ Subdomain cannot be empty (current: '${test_value:-empty}').${NC}" >&2
            valid=false
          elif [[ "$test_value" =~ [^a-z0-9] ]]; then
            echo -e "${RED}❌ Subdomain must contain only lowercase letters and numbers (no spaces, symbols, or hyphens) (current: '${test_value:-empty}').${NC}" >&2
            valid=false
          else
            break
          fi
        fi
        ;;
      *)
        ;;
    esac
  done

  $valid && return 0 || return 1
}

# Function to ask for variable and perform validation until valid input is provided
ask_and_validate() {
  local var_name="$1"
  local prompt="$2"
  local current_value="$3"
  local value

  while true; do
    value=$(get_input "$var_name" "$prompt" "$current_value")

    # Non-interactive: skip retries but still validate
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
      if ! validate_variables "$var_name" "$value" >/dev/null; then
        echo -e "${YELLOW}⚠️ Skipping $var_name validation in non-interactive mode (value: '$value').${NC}" >&2
      fi
      echo "$value"
      return 0
    fi

    # Temporarily assign value for validation
    # export "${var_name}=${value}"

    # Temporarily assign global value for validation (not exported)
    declare -g "${var_name}=${value}"

    # Interactive validation
    if validate_variables "$var_name"; then
      echo "$value"
      return 0
    fi
  done
}

# Check for updates to the containers
run_updates() {
  local update_mode="${1:-}"

  if [[ -z "$update_mode" ]]; then
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
      update_mode="auto-apply"  # Default to auto-apply in non-interactive mode
    else
      update_mode="interactive"  # Default to interactive mode for update_containers.sh if not provided
    fi
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
  REPO="${username}/${new_repo}"

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
  echo "Installing docker... you may need to enter your password for the 'sudo' command."
  # Get OS distribution
  source /etc/os-release
  case $ID in
    ubuntu)
      echo "Installing Docker for Ubuntu..."
      sudo apt-get update && sudo apt-get install ca-certificates curl -y && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
      if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker install failed. Please install Docker to proceed.${NC}"
        exit 1
      else
        echo -e "${GREEN}✅ Docker installation for Ubuntu complete!${NC}"
      fi
    ;;
    debian)
      echo "Installing Docker for Debian.."
      sudo apt-get update && sudo apt-get install ca-certificates curl -y && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
      if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker install failed. Please install Docker to proceed.${NC}"
        exit 1
      else
        echo -e "${GREEN}✅ Docker installation for Debian complete!${NC}"
      fi
    ;;
    *)
      echo -e "${RED}❌ Distribution is not supported by this script! Please install Docker manually.${NC}"
      exit 1
    ;;
  esac

  if ! command -v docker >/dev/null 2>&1; then
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
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}❌ jq install failed. Please install jq to proceed.${NC}"
    exit 1
  else
    echo -e "${GREEN}✅ jq installation complete!${NC}"
    fi
fi

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
  # Display versions of existing files and prompt to update if out of date
  update_files
  echo "🔍 Parsing current .env variables:"
else
  download_file $DEFAULT_ENV_URL ".env"
  # Display versions of existing files and prompt to update if out of date
  update_files
  echo "🔍 Parsing default .env variables:"
fi

# Read the .env file and export the variables, save build args to OLD_ARGS and print env file contents
parse_env "$ENV_FILE"
print_env

# Function for the GitHub configuration flow to configure GITHUB_PAT and REPO
configure_github() {
  # Get GITHUB_PAT and validate input is not default or empty
  GITHUB_PAT=$(ask_and_validate GITHUB_PAT "🔑 Enter your GitHub Personal Access Token, required scopes are read:org, workflow, read:packages, repo:" "$GITHUB_PAT")

  # Only continue if PAT is set
  if [[ -n "$GITHUB_PAT" ]]; then
    # Validate the GITHUB_PAT by using the GitHub CLI to login
    validate_github_user "$GITHUB_PAT" || exit 1

    # Set a default GitHub REPO name based on the DOMAIN name if not already set
    if [[ -z "$REPO" || "$REPO" == "username/repo" ]]; then
      REPO="${DOMAIN}-image-builder"
    fi

    # Get the GitHub REPO name and then validate it exists or create it from template if it does not exist
    while true; do
      REPO=$(ask_and_validate REPO "🐙 Enter your GitHub Repository (either 'repo' or 'username/repo'). The username will be set to '$GH_USER':" "$REPO")

      # Reject blank/default
      if [[ -z "$REPO" || "$REPO" == "username/repo" || "$REPO" == "repo" ]]; then
        echo -e "${RED}❌ Repository is blank or still set to default.${NC}"
        continue
      fi

      # Strip username if provided
      if [[ "$REPO" == */* ]]; then
        repo_name="${REPO#*/}"
      else
        repo_name="$REPO"
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
        else
          echo -e "${YELLOW}⚠️ Setting GITHUB_PAT and REPO back to defaults.${NC}"
          GITHUB_PAT=""
          REPO="username/repo"
        fi
      else
        # set the temp repo value to the correct format, if user confirms at the update .env prompt it will be written to .env
        REPO="${username}/${repo_name}"
      fi
      break
    done
  else
    # If GITHUB_PAT is blank, reset REPO to default
    REPO="username/repo"
  fi
}

# Ask to configure .env values
if [[ "$(get_input "❓ Change the .env file variables? (y/n)" "n" )" =~ ^[Yy]$ ]]; then
  # Configuration walkthrough questions. Questions will pull existing or default values from the sourced .env file
  echo
  echo -e "Answer the following questions to update your compose .env variables."
  echo "Press ENTER to accept the existing values that are between the brackets [ ]."
  echo "You will be asked to confirm the changes before the file is modified."
  echo
  # ====== START variable questions ======

  # ====== START REQUIRED variables ======
  # Get domain name and validate input is not default, empty, or not in valid domain format
  DOMAIN=$(ask_and_validate DOMAIN "🌐 Enter your domain name (e.g., yourdomain.com):" "$DOMAIN")

  # If no repo is configured, display a warning message if less than 16GB of RAM is detected to encourage adding more RAM or confiure GitHub
  if [[ -z "$REPO" || "$REPO" == "username/repo" || ! "$REPO" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]]; then
    if ! memory_check; then
      echo -e "⚡ ${Yellow}If the images fail to build either add more system memory or configure GitHub for building images remotely.${NC}"
    fi
  fi

  if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
    echo -e "${CYAN}ℹ️ Non-interactive mode enabled.${NC}"
    configure_github
  else
    # Interactive mode (ask user)
    if [[ "$(get_input "❓ Update GitHub configuration for building Remote Falcon images remotely on GitHub? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      if [[ -n "$REPO" && "$REPO" != "username/repo" ]]; then
        echo -e "${YELLOW}⚠️ Existing GitHub configuration detected: $REPO${NC}"

        case "$(get_input "❓ Choose an option: [1] Disable remote builds  [2] Modify config  [3] Keep as-is" "3")" in
          1)
            echo -e "${YELLOW}⚠️ Disabling remote builds.${NC}"
            GITHUB_PAT=""
            REPO="username/repo"
            ;;
          2)
            configure_github
            ;;
          3)
            echo -e "${CYAN}ℹ️ Keeping existing configuration.${NC}"
            ;;
        esac
      else
        configure_github
      fi
    fi
  fi

  # Get the Cloudflared tunnel token and validate input is not default, empty, or not in valid format
  if [[ "${NON_INTERACTIVE:-false}" == "false" && ( "$TUNNEL_TOKEN" == "cloudflare_token" || -z "$TUNNEL_TOKEN" ) ]]; then
    echo -e "${YELLOW}⚠️ TUNNEL_TOKEN is not set or is set to the default value.${NC}"
    if [[ "$(get_input "❓ Run the automatic Cloudflare configuration script? You will need a Cloudflare API token (y/n)" "n")" =~ ^[Yy]$ ]]; then
      if [ -f "$SCRIPT_DIR/setup_cloudflare.sh" ]; then
        bash "$SCRIPT_DIR/setup_cloudflare.sh"

        if [[ -z "$TUNNEL_TOKEN" && -f "tunnel_token.txt" ]]; then
          TUNNEL_TOKEN=$(<tunnel_token.txt)
        fi
      else
        echo -e "${YELLOW}⚠️ setup_cloudflare.sh script not found. Skipping automatic Cloudflare configuration.${NC}"
        TUNNEL_TOKEN=$(ask_and_validate TUNNEL_TOKEN "🔐 Enter your Cloudflare Tunnel token:" "$TUNNEL_TOKEN")
      fi
    else
      TUNNEL_TOKEN=$(ask_and_validate TUNNEL_TOKEN "🔐 Enter your Cloudflare Tunnel token:" "$TUNNEL_TOKEN")
    fi
  else
    TUNNEL_TOKEN=$(ask_and_validate TUNNEL_TOKEN "🔐 Enter your Cloudflare Tunnel token:" "$TUNNEL_TOKEN")
  fi

  # Validate auto validate email input, only accept true or false
  AUTO_VALIDATE_EMAIL=$(ask_and_validate AUTO_VALIDATE_EMAIL "📧 Enable auto validate email? While set to 'true' anyone can create a viewer page account on your site (true/false):" "$AUTO_VALIDATE_EMAIL" | tr '[:upper:]' '[:lower:]')

  # Removed this HOSTNAME_PARTS question to avoid issues - .env can be manually edited if you have ACM and want a 3 part domain.
  #echo "Enter the number of parts in your hostname. For example, domain.com would be two parts ('domain' and 'com'), and sub.domain.com would be 3 parts ('sub', 'domain', and 'com')"
  #HOSTNAME_PARTS=$(ask_and_validate HOSTNAME_PARTS "Cloudflare free only supports two parts for wildcard domains without Advanced Certicate Manager(\$10/month):" "$HOSTNAME_PARTS" )
  #echo

  if [[ $HOSTNAME_PARTS == 3 ]]; then
    echo -e "${YELLOW}⚠️ You are using a 3 part domain. Please ensure you have Advanced Certificate Manager enabled in Cloudflare.${NC}"
  fi

  if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
    echo -e "${YELLOW}⚠️ Skipping origin certificate/key configuration in non-interactive mode.${NC}"
  else
    # Ask if Cloudflare origin certificates should be updated if they exist. Otherwise prompt if cert/key files are missing
    # This will create the cert/key in the current directory and append the domain name to the beginning of the file name
    if [[ -f "${DOMAIN}_origin_cert.pem" && -f "${DOMAIN}_origin_key.pem" ]]; then
      if [[ "$(get_input "❓ Update existing origin certificate and key? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        read -p "Press ENTER to open nano to paste the origin certificate. Ctrl+X, y, and ENTER to save."
        nano "${DOMAIN}_origin_cert.pem"
        read -p "Press ENTER to open nano to paste the origin private key. Ctrl+X, y, and ENTER to save."
        nano "${DOMAIN}_origin_key.pem"
      fi
    else
      # If origin cert missing
      if [[ ! -f "${DOMAIN}_origin_cert.pem" ]]; then
        echo -e "${YELLOW}⚠️ Origin certificate ${DOMAIN}_origin_cert.pem not found. Please paste it now.${NC}"
        read -p "Press ENTER to open nano to paste the origin certificate. Ctrl+X, y, and ENTER to save."
        nano "${DOMAIN}_origin_cert.pem"
      fi

      # If origin key missing
      if [[ ! -f "${DOMAIN}_origin_key.pem" ]]; then
        echo -e "${YELLOW}⚠️ Origin private key ${DOMAIN}_origin_key.pem not found. Please paste it now.${NC}"
        read -p "Press ENTER to open nano to paste the origin private key. Ctrl+X, y, and ENTER to save."
        nano "${DOMAIN}_origin_key.pem"
      fi
    fi
  fi
  # ====== END REQUIRED variables ======

  # ====== START OPTIONAL variables ======
  if [[ "$(get_input "❓ Update OPTIONAL variables? (y/n)" "n")" =~ ^[Yy]$ ]]; then
    # Ask if SEQUENCE_LIMIT variable should be updated
    SEQUENCE_LIMIT=$(ask_and_validate SEQUENCE_LIMIT "🎶 Enter desired sequence limit:" "$SEQUENCE_LIMIT")

    # Validate SWAP_CP input, only accept true or false
    #echo -e "🔁 SWAP_CP = true will make your\n  Viewer Page Subdomain accessible at: ${BLUE}🔗 https://$DOMAIN${NC}\n  Control Panel accessible at: ${BLUE}🔗 https://controlpanel.$DOMAIN${NC}"
    #echo -e "🔁 SWAP_CP = false will make your\n  Control Panel accessible at: ${BLUE}🔗 https://$DOMAIN${NC}\n  Viewer Page Subdomain accessible at: ${BLUE}🔗 https://yoursubdomain.$DOMAIN${NC}"
    echo -e "🔁 SWAP_CP = true  →  Viewer: ${BLUE}🔗 https://$DOMAIN${NC}  |  Control Panel: ${BLUE}🔗 https://controlpanel.$DOMAIN${NC}"
    echo -e "🔁 SWAP_CP = false →  Control Panel: ${BLUE}🔗 https://$DOMAIN${NC} |  Viewer: ${BLUE}🔗 https://yoursubdomain.$DOMAIN${NC}"
    SWAP_CP=$(ask_and_validate SWAP_CP "❓ Enable or disable swapping the Control Panel and Viewer Page Subdomain URLS? (true/false):" "$SWAP_CP" | tr '[:upper:]' '[:lower:]')

    # If SWAP_CP is set to true ask to update the Viewer Page Subdomain
    if [[ $SWAP_CP == true ]]; then
      VIEWER_PAGE_SUBDOMAIN=$(ask_and_validate VIEWER_PAGE_SUBDOMAIN "🌐 Enter your Viewer Page Subdomain:" "$VIEWER_PAGE_SUBDOMAIN")

      # Remove all whitespace (leading, trailing, and internal)
      VIEWER_PAGE_SUBDOMAIN=$(echo "$VIEWER_PAGE_SUBDOMAIN" | tr -d '[:space:]')
      # Convert to lowercase
      VIEWER_PAGE_SUBDOMAIN=$(echo "$VIEWER_PAGE_SUBDOMAIN" | tr '[:upper:]' '[:lower:]')
    fi

    GOOGLE_MAPS_KEY=$(get_input GOOGLE_MAPS_KEY "🗺️ Enter your Google maps key:" "$GOOGLE_MAPS_KEY")

    # Ask if SOCIAL_META variable should be updated
    if [[ "$(get_input "❓ Update social meta tag? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      echo "See the RF docs for details on the SOCIAL_META tag:"
      echo -e "${BLUE}🔗 https://docs.remotefalcon.com/docs/developer-docs/running-it/digitalocean-droplet?#update-docker-composeyaml${NC}"
      echo
      echo -e "🏷️ Update SOCIAL_META tag or leave as default - Enter on one line only"
      echo
      SOCIAL_META=$(get_input SOCIAL_META "" "$SOCIAL_META")
    fi

    # Ask if analytics env variables should be set for PostHog, Google Analytics, or Mixpanel
    if [[ "$(get_input "❓ Update analytics variables? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      PUBLIC_POSTHOG_KEY=$(get_input PUBLIC_POSTHOG_KEY "📊 Enter your PostHog key - https://posthog.com/:" "$PUBLIC_POSTHOG_KEY")
      GA_TRACKING_ID=$(get_input GA_TRACKING_ID "Enter your Google Analytics Measurement ID - https://analytics.google.com/:" "$GA_TRACKING_ID")
      MIXPANEL_KEY=$(get_input MIXPANEL_KEY "📊 Enter your Mixpanel key - https://mixpanel.com/:" "$MIXPANEL_KEY")
      CLARITY_PROJECT_ID=$(get_input CLARITY_PROJECT_ID "📊 Enter your Microsoft Clarity code - https://clarity.microsoft.com/:" "$CLARITY_PROJECT_ID")
    fi
  fi

  # Ensure optional variables are set to the current values regardless if they were updated or not
  REPO=${REPO:-$REPO}
  GITHUB_PAT=${GITHUB_PAT:-$GITHUB_PAT}
  HOSTNAME_PARTS=${HOSTNAME_PARTS:-$HOSTNAME_PARTS}
  GOOGLE_MAPS_KEY=${GOOGLE_MAPS_KEY:-$GOOGLE_MAPS_KEY}
  PUBLIC_POSTHOG_KEY=${PUBLIC_POSTHOG_KEY:-$PUBLIC_POSTHOG_KEY}
  GA_TRACKING_ID=${GA_TRACKING_ID:-$GA_TRACKING_ID}
  MIXPANEL_KEY=${MIXPANEL_KEY:-$MIXPANEL_KEY}
  CLARITY_PROJECT_ID=${CLARITY_PROJECT_ID:-$CLARITY_PROJECT_ID}
  SOCIAL_META=${SOCIAL_META:-$SOCIAL_META}
  SEQUENCE_LIMIT=${SEQUENCE_LIMIT:-$SEQUENCE_LIMIT}
  VIEWER_PAGE_SUBDOMAIN=${VIEWER_PAGE_SUBDOMAIN:-$VIEWER_PAGE_SUBDOMAIN}
  SWAP_CP=${SWAP_CP:-$SWAP_CP}
  # ====== END OPTIONAL variables ======

  # ====== START BUILD ARGs ======
  # Capture the current values of any BUILD args(from sourced .env) that weren't asked for above
  VERSION=${VERSION:-$VERSION}
  HOST_ENV=${HOST_ENV:-$HOST_ENV}
  PUBLIC_POSTHOG_HOST=${PUBLIC_POSTHOG_HOST:-$PUBLIC_POSTHOG_HOST}
  OTEL_OPTS=${OTEL_OPTS:-$OTEL_OPTS}
  OTEL_URI=${OTEL_URI:-$OTEL_URI}
  MONGO_URI=${MONGO_URI:-$MONGO_URI}

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
          # Run interactive updates since update_containers will verify if the image exists in the REPO and build indvidually if missing
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