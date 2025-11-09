#!/bin/bash

# VERSION=2025.11.8.1

# This script will check for and display updates for containers: cloudflared, nginx, mongo,  minio, plugins-api, control-panel, viewwer, ui, and external-api.
# ./update_containers.sh all
# ./update_containers.sh cloudflared
# ./update_containers.sh nginx
# Include 'health' as the third argument to run the health check script after updating.
# Usage: ./update_containers.sh [all|mongo|minio|nginx|cloudflared|plugins-api|control-panel|viewer|ui|external-api] [dry-run|auto-apply|interactive] [health]

#set -euo pipefail
#set -x

# ========== Config ==========
# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/shared_functions.sh" ]]; then
  echo -e "${RED}❌ ERROR: shared_functions.sh does not exist in $SCRIPT_DIR.${NC}"
  exit 1
fi

source "$SCRIPT_DIR/shared_functions.sh"

# REPO and GITHUB_PAT is pulled from .env via parse_env in shared_functions.sh
check_env_exists
parse_env

SERVICE_NAME="${1:-}" # Options: all, mongo, minio, nginx, cloudflared
MODE="${2:-}"  # Options: dry-run, auto-apply, or interactive, defaults to interactive if not provided
HEALTH_CHECK="${3:-}" # Options: health or empty
# CONTAINERS defines the order that the containers will be updated in if no name is provided
CONTAINERS=("mongo" "minio" "plugins-api" "control-panel" "viewer" "ui" "external-api" "nginx" "cloudflared" )
BACKED_UP=false # Flag to track if a backup was made
REMOTE_FALCON_REPO="Remote-Falcon/remote-falcon-" # Main repo to compare sha

if [[ -z "$SERVICE_NAME" ]]; then
  SERVICE_NAME="all"  # Default to all if not provided
fi

if [[ -z "$MODE" ]]; then
  MODE="interactive"  # Default to interactive mode if not provided
fi

if [[ -z "$HEALTH_CHECK" ]]; then
  HEALTH_CHECK=false  # Default to false if not provided
fi

# ========== Functions ==========
# Get a registry access token for GHCR
get_token() {
  local image=$1
  # Request token using GitHub username and PAT
  local response

  response=$(curl -s -u "user:$GITHUB_PAT" \
  "https://ghcr.io/token?scope=repository:${REPO}/${image}:pull" -w "%{http_code}")

  # Extract HTTP code (last 3 chars) and body
  local http_code="${response: -3}"
  local body="${response:: -3}"

  if [[ "$http_code" != "200" ]]; then
    echo "❌ Token exchange failed for $image (HTTP $http_code)"
    echo "Response: $body"
    return 1
  fi

  # Extract and return token
  echo "$body" | jq -r .token
}

# After getting a token, check if image exists in GHCR
check_image_exists() {
  local image=$1
  local tag=$2

  # Get a short-lived token for this image
  local token
  token=$(get_token "$image") || return 1

  # Query the manifest for the specific tag
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/${REPO}/${image}/manifests/$tag")

  if [[ "$status" == "200" ]]; then
    echo -e "🐳 Image ghcr.io/${REPO}/$image:${GREEN}$tag${NC} exists in the GitHub Container Registry(GHCR)."
    return 0
  elif [[ "$status" == "404" ]]; then
    echo -e "${RED}❌ Image ghcr.io/${REPO}/$image:$tag does not exist in GitHub Container Registry(GHCR).${NC}"
    return 1
  else
    echo -e "${YELLOW}⚠️ Unexpected response checking $image:$tag – HTTP $status${NC}"
    return 2
  fi
}

# Function to get the latest version(s) for a container from its release notes
get_latest_version() {
  local service_name=$1

  case "$service_name" in
    "cloudflared")
      grep -Eo '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$' | head -n 1
      ;;
    "nginx")
      grep -Eo 'nginx [0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | awk '{print $2}'
      ;;
    "mongo")
      grep -oP 'mongo:\K[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | grep -v -- '-' | sort -Vu
      ;;
    "minio")
      grep -oP '"tag_name":\s*"\KRELEASE\.\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z' | head -n 1
      ;;
    plugins-api|control-panel|viewer|ui|external-api)
      # Map shorthand service name to actual repo name
      local full_sha=$(curl -s "https://api.github.com/repos/${REMOTE_FALCON_REPO}${service_name}/commits/main" | jq -r .sha)
      echo "$full_sha"
      ;;
    *)
      echo -e "${RED}❌ Failed to fetch latest version. Unsupported container: $service_name${NC}" >&2
      exit 1
      ;;
  esac
}

# Function to perform the update to compose.yaml and restart the container
# If the service is mongo, it will also backup the mongo data before updating
perform_update() {
  local service_name="$1"
  local latest_version="$2"
  local sed_command="$3"

  if [[ $service_name == "mongo" ]]; then
    backup_mongo "mongo"
  fi
  if [[ $BACKED_UP == false ]]; then
    backup_file "$COMPOSE_FILE"
    BACKED_UP=true
  fi

  case "$service_name" in
    plugins-api|control-panel|viewer|ui|external-api)
      # Update the build context line in compose.yaml to allow local builds from the correct commit
      sed -i -E "s|(context: https://github.com/Remote-Falcon/remote-falcon-${service_name}\.git)(#.*)?|\1#$latest_version|g" "$COMPOSE_FILE"
      latest_version=${latest_version:0:7} # Use short sha for image tag
      # Update the image tag in the compose.yaml
      sed -i.bak -E "s|(^[[:space:]]*image:[[:space:]]*\"?)([^\"[:space:]]*${service_name}):[^\"[:space:]]+(\"?)|\1\2:${latest_version}\3|" "$COMPOSE_FILE"
      ;;
    *)
      # Update the image tag in compose.yaml for non-RF images
      sed -i.bak -E "$sed_command" "$COMPOSE_FILE"
      ;;
  esac

  echo -e "✔ Updated $service_name image tag to version $latest_version in $COMPOSE_FILE..."
  echo -e "${BLUE}🔄 Restarting $service_name with the $latest_version image...${NC}"
  sudo docker compose -f "$COMPOSE_FILE" up -d "$service_name"
}

# Function to check the $MODE and update the container image tag in the compose.yaml if auto-apply is selected or if the user confirms
prompt_to_update() {
  local service_name="$1"
  local latest_version="$2"
  local sed_command="$3"

  case "$MODE" in
    "dry-run")
      case "$service_name" in
        plugins-api|control-panel|viewer|ui|external-api)
          echo -e "🧪 ${YELLOW}Dry-run:${NC} would update $service_name to ${latest_version:0:7}"
          ;;
        *)
          echo -e "🧪 ${YELLOW}Dry-run:${NC} would update $service_name to $latest_version"
          ;;
      esac
      ;;
    "auto-apply")
      perform_update "$service_name" "$latest_version" "$sed_command"
      ;;
    *)
      case "$service_name" in
        plugins-api|control-panel|viewer|ui|external-api)
        read -p "❓ Update $service_name to ${latest_version:0:7}? (y/n) [n]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          perform_update "$service_name" "$latest_version" "$sed_command"
        else
          echo -e "⏭️ Skipped $service_name update."
        fi
        ;;
      *)
        read -p "❓ Update $service_name to ${latest_version}? (y/n) [n]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          perform_update "$service_name" "$latest_version" "$sed_command"
        else
          echo -e "⏭️ Skipped $service_name update."
        fi
        ;;
      esac
      ;;
    esac
}

# ========== Main update logic ==========
# If REPO and GITHUB_PAT are configured, validate GitHub CLI and GHCR docker login are successful in order to build and pull images, these are in shared_functions.sh
# Validate the REPO variable is set to a non-default value in the correct format
if [[ ! -z "$REPO" && ! "$REPO" == "username/repo" && "$REPO" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ && ! -z "$GITHUB_PAT" ]]; then
  validate_github_user "$GITHUB_PAT" || exit 1
  validate_github_repo "$REPO" || exit 1
  validate_docker_user || exit 1
fi
# Removes or adds ghcr.io/${REPO}/ prefix to the compose.yaml image paths based on the current $REPO value configured in the .env
update_compose_image_path

check_for_update() {
  local service_name="$1"
  CURRENT_VERSION=""

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}📦 Container: $service_name${NC}"

  # Check if the container is NOT running, for non-RF containers start if not started to get version directly, for RF containers check compose.yaml for tag
  if ! is_container_running "$service_name"; then
    echo -e "${YELLOW}⚠️ $service_name does not exist or is not running.${NC}"
    case "$service_name" in
      cloudflared|nginx|mongo|minio)
        echo -e "${BLUE}🔄 Attempting to start $service_name to check its version directly...${NC}"
        sudo docker compose -f "$COMPOSE_FILE" up -d "$service_name"
        # Retry up to 10 times to get the current version from the running container if it was just started
        if [[ -z "$CURRENT_VERSION" ]]; then
          for i in {1..10}; do
            CURRENT_VERSION=$(get_current_version "$service_name")
            if [[ -n "$CURRENT_VERSION" ]]; then
              break
            fi
            echo -e "${YELLOW}⏳ Waiting for $service_name to be ready (attempt $i/10)...${NC}"
            sleep 1
          done

          # Fail if we still can't get the current version
          if [[ -z "$CURRENT_VERSION" ]]; then
            echo -e "${RED}❌ Failed to fetch the current version for $service_name after 10 attempts.${NC}"
            exit 1
          fi
        fi
        ;;
      plugins-api|control-panel|viewer|ui|external-api)
        # If RF containers aren't started, check compose.yaml for version tag
        echo -e "${BLUE}🔍 Checking $service_name tag in $COMPOSE_FILE...${NC}" 

        CURRENT_VERSION=$(get_current_compose_tag "$service_name") || CURRENT_VERSION=""
        ;;
      *)
        echo -e "${RED}❌ Unsupported container: $service_name${NC}" >&2
        exit 1
        ;;
    esac
  else
    # If the container is running, get the current version from the running container or for RF the running image tag
    CURRENT_VERSION=$(get_current_version "$service_name")
  fi

  # Fail if we still can't get the current version
  if [[ -z "$CURRENT_VERSION" ]]; then
    echo -e "${RED}❌ Failed to get the current version for $service_name.${NC}"
    exit 1
  fi

  # Set RELEASE_NOTES_URL based on the service name
  case "$service_name" in
    "cloudflared")
      RELEASE_NOTES_URL="https://raw.githubusercontent.com/cloudflare/cloudflared/refs/heads/master/RELEASE_NOTES"
      ;;
    "nginx")
      RELEASE_NOTES_URL="https://nginx.org/en/CHANGES"
      ;;
    "mongo")
      RELEASE_NOTES_URL="https://raw.githubusercontent.com/docker-library/repo-info/refs/heads/master/repos/mongo/tag-details.md"
      ;;
    "minio")
      RELEASE_NOTES_URL="https://api.github.com/repos/minio/minio/releases"
      ;;
    plugins-api|control-panel|viewer|ui|external-api)
      RELEASE_NOTES_URL="https://github.com/${REMOTE_FALCON_REPO}${service_name}/commits/main/"
      ;;
    *)
      echo -e "${RED}❌ Unsupported container: $service_name${NC}" >&2
      exit 1
      ;;
  esac

  # Fetch the release notes for the service from $RELEASE_NOTES_URL and store them in release_notes
  local release_notes=$(curl -s "$RELEASE_NOTES_URL" || true)
  if [[ -z "$release_notes" ]]; then
    echo -e "${RED}❌ Failed to fetch release notes for $service_name from $RELEASE_NOTES_URL${NC}"
  else
    # Fetch latest version(s) from the release notes
    LATEST_VERSION=$(echo "$release_notes" | get_latest_version "$service_name" || true)
  fi

  if [[ "$LATEST_VERSION" == "null" || -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}❌ Failed to determine latest version for $service_name. Try running update_containers.sh again. ${NC}"
    exit 1
  fi

  # Update logic for each container: cloudflared, nginx, mongo, minio
  case "$service_name" in
      "cloudflared")
        sed_command="s|cloudflare/$service_name:[^[:space:]]+|cloudflare/$service_name:$LATEST_VERSION|"
        format="^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$"
        # Check if the current version is in the valid XXXX.XX.X XXXX.X.X format
        check_tag_format "$service_name" "$CURRENT_VERSION"
        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$LATEST_VERSION${NC}"
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if [[ "$(get_current_compose_tag "$service_name")" != "$format" ]]; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tag $service_name $LATEST_VERSION
          fi
        else
          echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_VERSION):${NC}"
          echo -e "${BLUE}🔗 https://github.com/cloudflare/cloudflared/compare/${CURRENT_VERSION}...${LATEST_VERSION}${NC}"
          prompt_to_update $service_name $LATEST_VERSION "s|cloudflare/$service_name:[^[:space:]]+|cloudflare/$service_name:$LATEST_VERSION|"
        fi
        ;;
      "nginx")
        sed_command="/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$LATEST_VERSION|"
        format="^[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}$"
        check_tag_format "$service_name" "$CURRENT_VERSION"
        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$LATEST_VERSION${NC}"
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if [[ "$(get_current_compose_tag "$service_name")" != "$format" ]]; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tag $service_name $LATEST_VERSION
          fi
        else
          echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_VERSION):${NC}"
          echo -e "${BLUE}🔗 https://nginx.org/en/CHANGES${NC}"
          prompt_to_update $service_name $LATEST_VERSION $sed_command
        fi
        ;;
      "mongo")
        check_tag_format "$service_name" "$CURRENT_VERSION"
        # Function to extract the major version from a version string
        get_major_version() {
          echo "$1" | cut -d'.' -f1
        }
        # Get the major version of the current MongoDB
        CURRENT_MAJOR=$(get_major_version "$CURRENT_VERSION")
        # Find the latest patch version for the current major version, excluding pre-releases(grep -v '-')
        LATEST_SAME_MAJOR=$(echo "$LATEST_VERSION" | grep -E "^$CURRENT_MAJOR\." | sort -V | tail -n 1)
        # Find the next major version available
        NEXT_MAJOR=$((CURRENT_MAJOR + 1))
        LATEST_NEXT_MAJOR=$(echo "$LATEST_VERSION" | grep -E "^$NEXT_MAJOR\." | sort -V | tail -n 1 || true)
        if [[ "$CURRENT_VERSION" == "$LATEST_SAME_MAJOR" && "$LATEST_NEXT_MAJOR" == "" ]]; then
          echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
          echo -e "🔹 Latest version: ${GREEN}$LATEST_SAME_MAJOR${NC}"
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if [[ "$(get_current_compose_tag "$service_name")" != "^[0-9]{1,2}\.[0-9]+\.[0-9]{1,2}$" ]]; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tag $service_name $LATEST_SAME_MAJOR
          fi
        else
          echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
          echo -e "🔹 Latest current major version: ${GREEN}$LATEST_SAME_MAJOR${NC}"
          if [[ -n "$LATEST_NEXT_MAJOR" ]]; then
            echo -e "🔹 Latest next major version: ${GREEN}$LATEST_NEXT_MAJOR${NC}"
          fi
          # Offer update to latest patch version within the current major
          if [[ "$CURRENT_VERSION" != "$LATEST_SAME_MAJOR" ]]; then
            echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_SAME_MAJOR):${NC}"
            echo -e "${BLUE}🔗 https://www.mongodb.com/docs/manual/release-notes/$CURRENT_MAJOR.0-changelog/${NC}"
            prompt_to_update $service_name $LATEST_SAME_MAJOR "/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$LATEST_SAME_MAJOR|"
          elif [[ -n "${LATEST_NEXT_MAJOR:-}" ]]; then
            # Offer update to the next major version
            echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_NEXT_MAJOR):${NC}"
            echo -e "${YELLOW}⚠️ See MongoDB release notes here to confirm upgrade paths:${NC}${BLUE}🔗 https://www.mongodb.com/docs/manual/release-notes/${NC}"
            prompt_to_update $service_name $LATEST_NEXT_MAJOR "/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$LATEST_NEXT_MAJOR|"
          fi
        fi
        ;;
      "minio")
        sed_command="s|coollabsio/minio:[^[:space:]]+|coollabsio/minio:$LATEST_VERSION|"
        format="^RELEASE\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$"
        check_tag_format "$service_name" "$CURRENT_VERSION"
        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$LATEST_VERSION${NC}"
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if [[ "$(get_current_compose_tag "$service_name")" != "$format" ]]; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tag $service_name $LATEST_VERSION
          fi
        else
          echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_VERSION):${NC}"
          echo -e "${BLUE}🔗 https://github.com/minio/minio/compare/${CURRENT_VERSION}...${LATEST_VERSION}${NC}"
          prompt_to_update "minio" $LATEST_VERSION $sed_command
        fi
        ;;
      plugins-api|control-panel|viewer|ui|external-api)
        short_sha=${LATEST_VERSION:0:7}
        # This isn't used in perform_update since I had issues getting this to work correctly, so there is a case statement just for the RF images in perform_update
        sed_command="s|(^[[:space:]]*image:[[:space:]]*\"?)([^\"[:space:]]*${service_name}):[^\"[:space:]]+(\"?)|\1\2:${latest_version}\3|"
        format="\b[0-9a-f]{7}\b"
        check_tag_format "$service_name" "$CURRENT_VERSION"
        correct_format=$? # Capture the return value of check_tag_format

        # Start the container if it is not running and the compose.yaml format is correct(not 'latest')
        if (( correct_format == 0 )) && ! is_container_running "$service_name"; then
          echo -e "${BLUE}🔄 $service_name tag ${YELLOW}$CURRENT_VERSION${BLUE} is in valid format. Attempting to start $service_name...${NC}"
          sudo docker compose -f "$COMPOSE_FILE" up -d "$service_name"
        fi

        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$short_sha${NC}"

        if [[ "$CURRENT_VERSION" == "$short_sha" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if [[ "$(get_current_compose_tag "$service_name")" != "$format" ]]; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tag $service_name $LATEST_VERSION
          fi
        else
          echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $short_sha):${NC}"
          echo -e "${BLUE}🔗 https://github.com/${REMOTE_FALCON_REPO}${service_name}/commits/main/${NC}"

          case "$MODE" in
            "dry-run")
              if [[ -z "$REPO" || "$REPO" == "username/repo" || ! "$REPO" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]]; then # No REPO configured = local build
                if (( correct_format == 0 )); then # No REPO configured and format is valid.
                  echo -e "🧪 ${YELLOW}Dry-run:${NC} would locally build and update $service_name to $short_sha"
                else # No REPO configured and format is NOT valid
                  echo -e "🧪 ${YELLOW}Dry-run:${NC} would re-tag $service_name and locally build and update $service_name to $short_sha"
                fi
              else # REPO configured
                if check_image_exists "$service_name" "$short_sha"; then # REPO configured and image exists
                  if (( correct_format == 0 )); then # REPO configured, image exists, and format is valid
                    echo -e "🧪 ${YELLOW}Dry-run:${NC} would update $service_name to $short_sha"
                  else # REPO configured, image exists, and format is NOT valid
                    echo -e "🧪 ${YELLOW}Dry-run:${NC} would re-tag $service_name and update $service_name to $short_sha"
                  fi
                else # REPO configured and image does not exist
                  if (( correct_format == 0 )); then # REPO configured, image does NOT exist, and format is valid
                    echo -e "🧪 ${YELLOW}Dry-run:${NC} would perform run_workflow.sh to build and push $service_name:$short_sha to $REPO"
                    echo -e "🧪 ${YELLOW}Dry-run:${NC} would update $service_name to $short_sha"
                  else # REPO configured, image does NOT exist, and format is NOT valid
                    echo -e "🧪 ${YELLOW}Dry-run:${NC} would perform run_workflow.sh to build and push $service_name:$short_sha to $REPO"
                    echo -e "🧪 ${YELLOW}Dry-run:${NC} would update $service_name to $short_sha"
                  fi
                fi
              fi
              ;;
            "auto-apply")
              if [[ -z "$REPO" || "$REPO" == "username/repo" || ! "$REPO" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]]; then # No REPO configured = local build
                update_rf_version # From shared_functions.sh
                perform_update "$service_name" "$LATEST_VERSION" "$sed_command" 
              else # REPO configured
                if check_image_exists "$service_name" "$short_sha"; then # REPO configured and image exists
                  perform_update "$service_name" "$LATEST_VERSION" "$sed_command" # $LATEST_VERSION will get converted to short sha in perform_update
                else # REPO configured and image does not exist
                  if bash "$SCRIPT_DIR/run_workflow.sh" "$service_name=$LATEST_VERSION"; then
                    perform_update "$service_name" "$LATEST_VERSION" "$sed_command"
                  else
                    echo -e "${RED}❌ GitHub workflow did not complete successfully for $service_name.${NC}"
                  fi
                fi
              fi
              ;;
            *)
              # Interactive mode - prompt to locally build if $REPO is not configured, else prompt to run the workflow to build on GitHub
              if [[ -z "$REPO" || "$REPO" == "username/repo" || ! "$REPO" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]]; then
                case "$service_name" in
                  plugins-api|viewer)
                    # From shared_function.sh display detected memory and warning if less than 16GB
                    memory_check
                    ;;
                esac
                read -p "❓ Would you like to build $service_name:$short_sha? (y/n) [n]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                  perform_update "$service_name" "$LATEST_VERSION" "$sed_command"
                else
                  echo -e "⏭️ Skipped building $service_name."
                fi
              else
                # Interactive mode - prompt to run workflow and prompt to update compose.yaml if workflow completes successfully
                if check_image_exists "$service_name" "$short_sha"; then # REPO configured and image exists
                  read -p "❓ Update $service_name to ${latest_version:0:7}? (y/n) [n]: " confirm
                  if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    perform_update "$service_name" "$LATEST_VERSION" "$sed_command" # $LATEST_VERSION will get converted to short sha in perform_update
                  fi
                else # REPO configured and image does not exist
                  read -p "❓ Would you like to build and push $service_name:$short_sha to repository $REPO with run_workflow.sh? (y/n) [n]: " confirm
                  if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    if bash "$SCRIPT_DIR/run_workflow.sh" "$service_name=$LATEST_VERSION"; then
                      perform_update "$service_name" "$LATEST_VERSION" "$sed_command" # $LATEST_VERSION will get converted to short sha in perform_update
                    else
                      echo -e "${RED}❌ GitHub workflow did not complete successfully for $service_name.${NC}"
                    fi
                  else
                    echo -e "⏭️ Skipped building $service_name."
                  fi
                fi
              fi
              ;;
          esac
        fi
        ;;
      *)
        echo -e "${RED}❌ Unsupported container: $service_name${NC}" >&2
        echo "Usage:"
        echo "./update_containers.sh [all|mongo|minio|nginx|cloudflared|plugins-api|control-panel|viewer|ui|external-api] [dry-run|auto-apply|interactive] [health]"
        echo "./update_containers.sh all"
        echo "./update_containers.sh cloudflared auto-apply"
        echo "./update_containers.sh external-api dry-run"
        echo "./update_containers.sh mongo"
        echo "./update_containers.sh minio auto-apply health"
        exit 1
        ;;
  esac
}

# Check if the compose file exists
check_compose_exists
# If script is run with 'all', loop through all containers by calling the check_for_update function otherwise just check the specified container
if [ "$SERVICE_NAME" == "all" ]; then
  echo -e "${BLUE}⚙️ Checking for container updates...${NC}"
  for container in "${CONTAINERS[@]}"; do
    check_for_update "$container"
  done
  echo -e "${GREEN}🚀 Done. Container update process complete.${NC}"
else # If a specific container is provided, check for updates for that container and auto-apply or prompt for confirmation or dry-run
  # Validate the container name
  if [[ ! " ${CONTAINERS[*]} " =~ " $SERVICE_NAME " ]]; then
    echo -e "${RED}❌ Error: Unknown container '$SERVICE_NAME'. Valid options are: all ${CONTAINERS[*]}${NC}"
  else
    check_for_update "$SERVICE_NAME"
  fi
fi

# Run the health check if specified with 'health' after all updates are done
health_check $HEALTH_CHECK
exit 0