#!/bin/bash

# VERSION=2026.5.29.1

#set -euo pipefail

# ./configure-rf.sh [-y|--non-interactive] [--docker-mode group|rootless|manual] [--set KEY=VALUE ...]

# Preserve the original single-file installation command. A standalone copy of
# configure-rf.sh bootstraps the latest checksummed public release, then starts
# the installed configurator. No GitHub login is required.
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$BOOTSTRAP_DIR/shared_functions.sh" ]]; then
  command -v curl >/dev/null || { echo "curl is required to install Remote Falcon." >&2; exit 1; }
  bootstrap_installer=$(mktemp)
  trap 'rm -f "$bootstrap_installer"' EXIT
  curl -fsSL --retry 3 -o "$bootstrap_installer" \
    https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/install.sh
  bash "$bootstrap_installer" --target "$BOOTSTRAP_DIR" --no-configure
  trap - EXIT
  rm -f "$bootstrap_installer"
  exec "$BOOTSTRAP_DIR/configure-rf.sh" "$@"
fi

NON_INTERACTIVE=false
DOCKER_MODE="${RF_DOCKER_MODE:-group}"
DEBUG_INPUT=false # Used to debug input parsing when running in NON_INTERACTIVE mode

declare -A OVERRIDES=()

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --docker-mode)
      DOCKER_MODE="${2:-}"
      shift 2
      ;;
    --docker-mode=*)
      DOCKER_MODE="${1#--docker-mode=}"
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
      echo "  --docker-mode MODE        Docker access: group (default), rootless, or manual"
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
    echo "  OVERRIDE: $k=[redacted]" >&2
  done
  echo "--------------------------------------------" >&2
fi

# Files come from a verified public release installed into this checkout.
SERVICES=(external-api ui plugins-api viewer control-panel cloudflared nginx mongo versitygw)
ANY_SERVICE_RUNNING=false
TEMPLATE_REPO="Ne0n09/remote-falcon-image-builder" # Template repo for image builder workflows

# new_build_args array to track if any build args changed that would require RF container rebuild
# For GHCR builds these get synced with sync_repo_secrets.sh
# "CONTROL_PANEL_API" "VIEWER_API" not included because we only want to track if DOMAIN is changed
#### This will need to be updated down in update_env() if any new build context args are added - sync_repo_secrets will also need to be updated

# Required companion files are installed together by install.sh.
download_file() {
  local filename=$1

  if [ ! -f "$filename" ]; then
    if [[ "$filename" == ".env" && -f .env.example ]]; then
      (umask 077; cp .env.example .env)
      echo -e "✔ ${GREEN}Created .env from the local example.${NC}"
      return
    fi
    echo -e "${RED}❌ Missing $filename. Run ./install.sh to restore the verified release.${NC}" >&2
    exit 1
  fi
}

echo -e "${BLUE}⚙️ Running ${RED}RF${NC} configuration script...${NC}"

# Download and source shared functions
download_file "shared_functions.sh"
chmod +x "shared_functions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/shared_functions.sh" ]]; then
  echo -e "${RED}❌ ERROR: shared_functions.sh does not exist in $SCRIPT_DIR.${NC}"
  exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared_functions.sh"

# Download extra helper scripts if they do not exist and make them executable
download_file "update_containers.sh"
download_file "health_check.sh"
download_file "versitygw_init.sh"
download_file "setup_cloudflare.sh"
download_file "run_workflow.sh"
download_file "sync_repo_secrets.sh"
chmod +x "shared_functions.sh" "update_containers.sh" "health_check.sh" "versitygw_init.sh" "setup_cloudflare.sh" "run_workflow.sh" "sync_repo_secrets.sh"

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

  # Answer prompt with override value in non-interactive mode or auto answer yes to yes/no
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
    printf '%s\n' "⚙️: $prompt [$(display_env_value "$key" "$default")]: $(display_env_value "$key" "$input")" >&2

    printf '%s' "$input"
    return 0
  fi

  # Interactive mode: prompt the user, keep any prompt output on stdout
  case "$key" in
    *TOKEN*|*PAT*|*PASSWORD*|*SECRET*|*PRIVATE*|*JWT*|*KEY*)
      read -rsp "$prompt [configured value hidden]: " input
      echo >&2 ;;
    *) read -rp "$prompt [$default]: " input ;;
  esac
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
    ["DOCKERFILE"]="$DOCKERFILE"
    ["NGINX_CERT"]="./${DOMAIN}_origin_cert.pem"
    ["NGINX_KEY"]="./${DOMAIN}_origin_key.pem"
    ["PROTOMAPS_API_KEY"]="$PROTOMAPS_API_KEY"
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
  )

  # If any of these are changed, an image rebuild will be required.
  declare -A new_build_args=(
    ["VERSION"]="$VERSION"
    ["HOST_ENV"]="$HOST_ENV"
    ["DOCKERFILE"]="$DOCKERFILE"
    ["DOMAIN"]="$DOMAIN"
    ["PROTOMAPS_API_KEY"]="$PROTOMAPS_API_KEY"
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
        echo -e "${BLUE}🔸 $key${NC}=${YELLOW}$(display_env_value "$key" "${new_env_vars[$key]}")${NC}"
      fi
    done
    for key in "${!new_env_vars[@]}"; do
      if [[ ! -v existing_env_vars[$key] ]]; then
        echo -e "${BLUE}🔸 $key${NC}=${YELLOW}$(display_env_value "$key" "${new_env_vars[$key]}")${NC}"
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
              echo -e "${RED}🔧 $key${NC}=${YELLOW}$(display_env_value "$key" "${new_build_args[$key]}")${NC}"
            fi
          fi
        done
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      fi
    fi
  fi

  # Validate the variables before writing to .env
  vars_to_validate=(TUNNEL_TOKEN DOMAIN AUTO_VALIDATE_EMAIL HOSTNAME_PARTS SEQUENCE_LIMIT SWAP_CP VIEWER_PAGE_SUBDOMAIN DOCKERFILE)
  echo -e "${CYAN}🔍 Validating variables: ${vars_to_validate[*]}${NC}"

  # Run validation
  if ! validate_variables "${vars_to_validate[@]}"; then
    echo -e "${RED}❌ Validation failed. The .env file was not updated.${NC}"
    exit 1
  else
    echo -e "${GREEN}✅ All environment variables validated successfully.${NC}"
  fi

  # Write the variables to the .env file if answer is y
  if [[ "$(get_input "❓ Update the .env file with the above values? (y/n)" "n" )" =~ ^[Yy]$ ]]; then
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
    (umask 077; awk '!seen[$0]++' .env > .env.tmp && mv .env.tmp .env)
    chmod 600 .env

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
      DOCKERFILE)
        if [[ "$test_value" != "Dockerfile" && "$test_value" != "Dockerfile.dev" ]]; then
          echo -e "${RED}❌ $var_name must be 'Dockerfile' or 'Dockerfile.dev' (current: '${test_value:-empty}').${NC}" >&2
          valid=false
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

  case "$update_mode" in
    auto-apply)
      bash "$SCRIPT_DIR/update_containers.sh" "all" "auto-apply"
      ;;
    *)
      # Interactive mode, default
      bash "$SCRIPT_DIR/update_containers.sh" "all"
      ;;
  esac
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
  echo -e "${YELLOW}ℹ️ The repository was created from the public image-builder template.${NC}"
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

case "$DOCKER_MODE" in
  group|rootless|manual) ;;
  *) echo -e "${RED}❌ Invalid --docker-mode '$DOCKER_MODE'. Use group, rootless, or manual.${NC}"; exit 2 ;;
esac

if [[ "$DOCKER_MODE" == "rootless" ]]; then
  if ! docker info 2>/dev/null | grep -qi rootless; then
    cat >&2 <<'ROOTLESS'
Rootless Docker is not active for this user. Follow
https://docs.docker.com/engine/security/rootless/, verify that `docker info`
lists "rootless" under Security Options, then rerun this command.
The configurator will not install a rootful daemon when rootless was selected.
ROOTLESS
    exit 2
  fi
fi

if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
  echo -e "${RED}❌ Docker is unavailable and sudo is not installed. Install Docker as root, then rerun this script.${NC}"
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

# Configure non-root Docker access only when it is actually needed. Permanent
# docker group membership is the practical default for a dedicated VM, but it
# grants root-level control of the host. Rootless conversion is never automatic.
if [[ $EUID -ne 0 ]] && ! docker info >/dev/null 2>&1; then
  case "$DOCKER_MODE" in
    group)
      echo -e "${YELLOW}⚠️ Docker group membership grants root-level privileges on this host.${NC}"
      sudo groupadd --force docker
      sudo usermod -aG docker "$USER"
      echo -e "${GREEN}✔ Added '$USER' to the docker group.${NC}"
      echo "Log out of this SSH/login session and back in, then rerun ./configure-rf.sh."
      exit 2
      ;;
    rootless)
      cat >&2 <<'ROOTLESS'
Rootless Docker must be configured explicitly before Remote Falcon setup.
Follow https://docs.docker.com/engine/security/rootless/, verify that
`docker info` shows Security Options: rootless, then rerun configure-rf.sh
with --docker-mode rootless. Existing rootful Docker data is not migrated.
ROOTLESS
      exit 2
      ;;
    manual)
      echo -e "${RED}❌ The current user cannot access Docker. Configure access and rerun.${NC}"
      exit 2
      ;;
  esac
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
  mkdir -m 700 -p "$BACKUP_DIR"
fi

# Change to the 'remotefalcon' directory and download compose.yaml and default.conf if they do not exist
cd "$WORKING_DIR" || { echo -e "${RED}❌ Failed to change directory to '$WORKING_DIR'. Exiting.${NC}"; exit 1; }
echo "✔  Working in directory: $(pwd)"
download_file "compose.yaml"
download_file "default.conf"

# Print existing .env file, if it exists, otherwise download the default .env file
if [ -f .env ]; then
  echo "✔  Found existing .env at $ENV_FILE."
  # Display versions of existing files and prompt to update if out of date
  echo "🔍 Parsing current .env variables:"
else
  download_file ".env"
  # Display versions of existing files and prompt to update if out of date
  echo "🔍 Parsing default .env variables:"
fi

# Read the .env file and export the variables, save build args to OLD_ARGS and print env file contents
chmod 600 "$ENV_FILE"
parse_env "$ENV_FILE"
DOCKERFILE="${DOCKERFILE:-Dockerfile.dev}"
ORIGIN_CERTS_CONFIGURED_BY_SETUP=false
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

configure_build_strategy() {
  local low_memory=false

  if ! memory_check; then
    low_memory=true
  fi

  if is_arm_cpu; then
    echo -e "${YELLOW}⚠️ ARM CPU detected. Skipping GitHub workflow setup because building ARM Remote Falcon images on GitHub-hosted runners is not feasible on free plans.${NC}"
    if [[ "$low_memory" == "true" ]] && ! github_workflow_builds_configured; then
      DOCKERFILE="Dockerfile.dev"
      echo -e "${YELLOW}⚠️ Setting DOCKERFILE=Dockerfile.dev for lower-memory local image builds.${NC}"
    fi
    return
  fi

  if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
    echo -e "${CYAN}ℹ️ Non-interactive mode enabled.${NC}"
    configure_github
    select_dockerfile_for_host "$low_memory"
    return
  fi

  if [[ "$low_memory" == "true" ]]; then
    local default_strategy="1"

    if github_workflow_builds_configured; then
      default_strategy="2"
      echo -e "${CYAN}ℹ️ Existing GitHub workflow build configuration detected: ${REPO}${NC}"
    fi

    echo -e "${YELLOW}⚠️ Choose how Remote Falcon images should be built:${NC}"
    echo -e "  ${YELLOW}1${NC}) Build locally with ${CYAN}Dockerfile.dev${NC} to build JVM-based images"
    echo -e "  ${YELLOW}2${NC}) Configure private GitHub repository to build native images and pull from GHCR"
    echo -e "  🔸 JVM builds with ${CYAN}Dockerfile.dev${NC} will build on low memory systems but will have higher memory usage." 
    echo -e "  🔸 GitHub workflow builds will use ${CYAN}Dockerfile${NC} to build native images on GitHub and pull them from GHCR, resulting in lower memory usage."

    case "$(get_input "❓ Choose image build strategy: [1-2]" "$default_strategy")" in
      2)
        if ! github_workflow_builds_configured; then
          configure_github
        fi
        if github_workflow_builds_configured; then
          DOCKERFILE="Dockerfile"
          echo -e "${CYAN}ℹ️ GitHub workflow builds will be used for Remote Falcon images.${NC}"
        else
          DOCKERFILE="Dockerfile.dev"
          echo -e "${YELLOW}⚠️ GitHub workflow builds are not configured. Keeping local lower-memory builds with DOCKERFILE=Dockerfile.dev.${NC}"
        fi
        ;;
      *)
        REPO="username/repo"
        GITHUB_PAT=""
        DOCKERFILE="Dockerfile.dev"
        echo -e "${CYAN}ℹ️ Local builds will use DOCKERFILE=Dockerfile.dev.${NC}"
        ;;
    esac
    return
  fi

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

  configure_build_strategy

  # Get the Cloudflared tunnel token and validate input is not default, empty, or not in valid format
#  if [[ "$TUNNEL_TOKEN" == "cloudflare_token" || -z "$TUNNEL_TOKEN" ]]; then
#    echo -e "${YELLOW}⚠️ TUNNEL_TOKEN is not set or is set to the default value.${NC}"
#  fi
  if [[ "${NON_INTERACTIVE:-false}" == "false" ]]; then
    CF_API_TOKEN=$(ask_and_validate CF_API_TOKEN "🔑 Enter your Cloudflare API Token to automatically configure Cloudflare or leave blank for manual configuration:" "$CF_API_TOKEN")
    if [[ -n "$CF_API_TOKEN" ]]; then
      if [ -f "$SCRIPT_DIR/setup_cloudflare.sh" ]; then
        if bash "$SCRIPT_DIR/setup_cloudflare.sh" --api-token "${CF_API_TOKEN}"; then
          if [[ -f "${DOMAIN}_origin_cert.pem" && -f "${DOMAIN}_origin_key.pem" ]]; then
            ORIGIN_CERTS_CONFIGURED_BY_SETUP=true
          fi
        fi

        if [[ -f "tunnel_token.txt" ]]; then
          TUNNEL_TOKEN=$(<tunnel_token.txt)
        fi
      else
        echo -e "${YELLOW}⚠️ setup_cloudflare.sh script not found. Skipping automatic Cloudflare configuration.${NC}"
        TUNNEL_TOKEN=$(ask_and_validate TUNNEL_TOKEN "🔐 Enter your Cloudflare Tunnel token:" "$TUNNEL_TOKEN")
      fi
    else # Manual configuration as CF_API_TOKEN is blank
      TUNNEL_TOKEN=$(ask_and_validate TUNNEL_TOKEN "🔐 Enter your Cloudflare Tunnel token:" "$TUNNEL_TOKEN")
    fi
  else # Non-interactive will always attempt automatic configuration if CF_API_TOKEN is set
    CF_API_TOKEN=$(ask_and_validate CF_API_TOKEN "🔑 Enter your Cloudflare API Token to automatically configure Cloudflare or leave blank for manual configuration:" "$CF_API_TOKEN")
    if [[ -n "$CF_API_TOKEN" ]]; then
      echo -e "${CYAN}ℹ️ CF_API_TOKEN is set, attempting automatic Cloudflare configuration...${NC}"
      if [ -f "$SCRIPT_DIR/setup_cloudflare.sh" ]; then
        if bash "$SCRIPT_DIR/setup_cloudflare.sh" -y --api-token "${CF_API_TOKEN}"; then
          if [[ -f "${DOMAIN}_origin_cert.pem" && -f "${DOMAIN}_origin_key.pem" ]]; then
            ORIGIN_CERTS_CONFIGURED_BY_SETUP=true
          fi
        fi

        if [[ -f "tunnel_token.txt" ]]; then
          TUNNEL_TOKEN=$(<tunnel_token.txt)
        fi
      else
        echo -e "${YELLOW}⚠️ setup_cloudflare.sh script not found. Skipping automatic Cloudflare configuration.${NC}"
        TUNNEL_TOKEN=$(ask_and_validate TUNNEL_TOKEN "🔐 Enter your Cloudflare Tunnel token:" "$TUNNEL_TOKEN")
      fi
    else
      TUNNEL_TOKEN=$(ask_and_validate TUNNEL_TOKEN "🔐 Enter your Cloudflare Tunnel token:" "$TUNNEL_TOKEN")
    fi
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
  elif [[ "$ORIGIN_CERTS_CONFIGURED_BY_SETUP" == "true" ]]; then
    echo -e "${GREEN}✅ Origin certificate and key were configured by setup_cloudflare.sh. Skipping manual certificate prompt.${NC}"
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
    SWAP_CP=$(ask_and_validate SWAP_CP "❓ Enable or disable SWAP_CP to swap the Control Panel and Viewer Page Subdomain URLS? (true/false):" "$SWAP_CP" | tr '[:upper:]' '[:lower:]')

    # If SWAP_CP is set to true ask to update the Viewer Page Subdomain
    if [[ $SWAP_CP == true ]]; then
      VIEWER_PAGE_SUBDOMAIN=$(ask_and_validate VIEWER_PAGE_SUBDOMAIN "🌐 Enter your Viewer Page Subdomain:" "$VIEWER_PAGE_SUBDOMAIN")

      # Remove all whitespace (leading, trailing, and internal)
      VIEWER_PAGE_SUBDOMAIN=$(echo "$VIEWER_PAGE_SUBDOMAIN" | tr -d '[:space:]')
      # Convert to lowercase
      VIEWER_PAGE_SUBDOMAIN=$(echo "$VIEWER_PAGE_SUBDOMAIN" | tr '[:upper:]' '[:lower:]')
    fi

    PROTOMAPS_API_KEY=$(get_input PROTOMAPS_API_KEY "🗺️ Enter your Protomaps API key (optional):" "$PROTOMAPS_API_KEY")

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
    fi
  fi

  # Ensure optional variables are set to the current values regardless if they were updated or not
  REPO=${REPO:-$REPO}
  GITHUB_PAT=${GITHUB_PAT:-$GITHUB_PAT}
  HOSTNAME_PARTS=${HOSTNAME_PARTS:-$HOSTNAME_PARTS}
  PROTOMAPS_API_KEY=${PROTOMAPS_API_KEY:-$PROTOMAPS_API_KEY}
  PUBLIC_POSTHOG_KEY=${PUBLIC_POSTHOG_KEY:-$PUBLIC_POSTHOG_KEY}
  GA_TRACKING_ID=${GA_TRACKING_ID:-$GA_TRACKING_ID}
  MIXPANEL_KEY=${MIXPANEL_KEY:-$MIXPANEL_KEY}
  SOCIAL_META=${SOCIAL_META:-$SOCIAL_META}
  SEQUENCE_LIMIT=${SEQUENCE_LIMIT:-$SEQUENCE_LIMIT}
  VIEWER_PAGE_SUBDOMAIN=${VIEWER_PAGE_SUBDOMAIN:-$VIEWER_PAGE_SUBDOMAIN}
  SWAP_CP=${SWAP_CP:-$SWAP_CP}
  # ====== END OPTIONAL variables ======

  # ====== START BUILD ARGs ======
  # Capture the current values of any BUILD args(from sourced .env) that weren't asked for above
  VERSION=${VERSION:-$VERSION}
  HOST_ENV=${HOST_ENV:-$HOST_ENV}
  DOCKERFILE=${DOCKERFILE:-Dockerfile.dev}
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

      # Check if the running container's tag is in the valid format. replacee_compose_tag is defined in shared_functions.sh
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
    # From shared_functions.sh, make sure compose.yaml uses the DOCKERFILE .env variable for RF builds
    update_compose_dockerfile_paths
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
              echo -e "${Green}✅ Workflow to build all Remote Falcon images to current versions completed successfully!${NC}"
          else
              echo -e "${RED}❌ Workflow to build all Remote Falcon images to current versions did not complete successfully, aborting.${NC}"
              exit 1
          fi
        else # If any service is running and $REPO is not configured, build locally
          echo -e "${YELLOW}⚠️ Containers are running. Build ARG changes detected. Running 'docker compose up -d --build --force-recreate' to apply any ARG and .env changes...${NC}"
          docker compose -f "$COMPOSE_FILE" up -d --build --force-recreate
        fi
      else # No ARGs changed, just run 'docker compose up -d' to pick up any environment variable changes
          echo -e "${YELLOW}⚠️ Containers are running. No build ARG changes detected. Running 'docker compose up -d' to apply any environmental variable changes...${NC}"
          docker compose -f "$COMPOSE_FILE" up -d --force-recreate
      fi

      # Prompt to check updates after applying new .env values to existing containers
      if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        run_updates
        versitygw_init
        health_check health
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
              versitygw_init
              health_check health
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
                docker compose -f "$COMPOSE_FILE" up -d --force-recreate
            else
              echo -e "${RED}❌ Workflow failed. Aborting.${NC}"
              exit 1
            fi
          fi
        else # No containers running, REPO not configured so images will be built locally
          if tag_has_latest; then
            echo -e "${BLUE}✨ Remote Falcon 'latest' image tags detected in compose.yaml, assuming new install, running update_containers.sh...${NC}"
            run_updates auto-apply
            versitygw_init
            health_check health
          else # Assume existing install since no 'latest' tags found, force local build and restart
            echo -e "${BLUE}🔄 Building Remote Falcon images to apply any updated build ARGs at their current version...${NC}"
            docker compose up -d --build --force-recreate
          fi
        fi
      else # No containers running, image rebuild not required(ARGs weren't changed in script)
        if tag_has_latest; then
          # Run run_updates auto-apply to tag containers
          echo -e "${GREEN}🚀 Bringing up existing containers to apply any .env changes...${NC}"
          run_updates auto-apply
          versitygw_init
          health_check health
        else # No containers running, no image rebuild required, and no 'latest' tags found so just bring the containers up
          # Run interactive updates since update_containers will verify if the image exists in the REPO and build indvidually if missing
          if [[ -n "$REPO" && "$REPO" != "username/repo" ]]; then
            echo -e "${GREEN}🚀 Bringing up stopped containers with update_container.sh...${NC}"
            run_updates
            versitygw_init
            health_check health
          else # No containers running, no image rebuild required, so just bring the containers up
            echo -e "${GREEN}🚀 Bringing up existing containers to apply any .env changes...${NC}"
            docker compose up -d
          fi
        fi
      fi
    fi
  else # update_env returned false - Ask to run update check anyway
    # Run validation to make sure default values aren't set
    vars_to_validate=(TUNNEL_TOKEN DOMAIN AUTO_VALIDATE_EMAIL HOSTNAME_PARTS SEQUENCE_LIMIT SWAP_CP VIEWER_PAGE_SUBDOMAIN DOCKERFILE)
    if validate_variables "${vars_to_validate[@]}"; then
      if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        run_updates
        versitygw_init
        health_check health
      elif [[ "$(get_input "❓ Run health check script? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        health_check health
      fi
    fi
  fi
else # User chose not to update the .env file
  echo -e "${YELLOW}⚠️ No .env variables modified.${NC}"
  # Run validation to make sure default values aren't set
  vars_to_validate=(TUNNEL_TOKEN DOMAIN AUTO_VALIDATE_EMAIL HOSTNAME_PARTS SEQUENCE_LIMIT SWAP_CP VIEWER_PAGE_SUBDOMAIN DOCKERFILE)
  if validate_variables "${vars_to_validate[@]}"; then
    if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      run_updates
      versitygw_init
      health_check health
    elif [[ "$(get_input "❓ Run health check script? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      health_check health
    fi
  fi
fi

echo -e "${YELLOW}⚠️ If running FPP 9 ensure Apache CSP is updated or sequences will not sync!${NC}"
echo -e "${BLUE}🔗 https://ne0n09.github.io/cloudflared-remotefalcon/post-install/${NC}"

echo -e "${GREEN}🎉 Done! Exiting ${RED}RF${NC}${GREEN} configuration script...${NC}"
exit 0
