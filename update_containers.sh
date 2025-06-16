#!/bin/bash

# VERSION=2025.6.6.1

# This script will check for and display updates for non-RF containers: cloudflared, nginx, mongo, and minio
# ./update_containers.sh all
# ./update_containers.sh cloudflared
# ./update_containers.sh nginx
# ./update_containers.sh mongo
# ./update_containers.sh minio
# Include 'health' as the third argument to run the health check script after updating.
# Usage: ./update_containers.sh [all|mongo|minio|nginx|cloudflared] [dry-run|auto-apply|interactive] [health]

#set -euo pipefail
#set -x

# ========== Config ==========
# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared_functions.sh"

SERVICE_NAME="${1:-}" # Options: all, mongo, minio, nginx, cloudflared
MODE="${2:-}"  # Options: dry-run, auto-apply, or interactive, defaults to interactive if not provided
HEALTH_CHECK="${3:-}" # Options: health or empty
# CONTAINERS defines the order that the containers will be updated in if no name is provided
CONTAINERS=("mongo" "minio" "nginx" "cloudflared")
BACKED_UP=false # Flag to track if a backup was made

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

# Check $CURRENT_VERSION is in the valid version format after running fetch_current_version
check_format() {
  local service_name="$1"
  local version="$2"
  local format_regex="$3"
  local format="$4"

  if [[ ! $version =~ $format_regex ]]; then
    echo -e "${YELLOW}⚠️ $service_name current version $version is not in the valid format ($format).${NC}"
  fi
}

# Function to fetch current version directly from the container after it is running
fetch_current_version() {
  local service_name=$1

  case "$service_name" in
    "cloudflared")
      sudo docker exec "$(get_container_name "$service_name")" cloudflared --version | sed -n 's/^cloudflared version \([0-9.]*\).*/\1/p'
      ;;
    "nginx")
      sudo docker exec "$(get_container_name "$service_name")" nginx -v 2>&1 | sed -n 's/^nginx version: nginx\///p'
      ;;
    "mongo")
      sudo docker exec "$(get_container_name "$service_name")" bash -c "mongod --version | grep -oP 'db version v\\K[\\d\\.]+'" | tr -d '[:space:]'
      ;;
    "minio")
      sudo docker exec "$(get_container_name "$service_name")" minio --version | sed -n 's/^minio version \(RELEASE\.[^ ]\+\).*/\1/p'
      ;;
    *)
      echo -e "${RED}❌ Failed to fetch current version. Unsupported container: $service_name${NC}" >&2
      exit 1
      ;;
  esac
}

# Function to fetch the latest version(s) for a container from its release notes
fetch_latest_version() {
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
    *)
      echo -e "${RED}❌ Failed to fetch latest version. Unsupported container: $service_name${NC}" >&2
      exit 1
      ;;
  esac
}

# Function to check the $MODE and update the container image tag in the compose.yaml if auto-apply is selected or if the user confirms
prompt_to_update() {
  local service_name="$1"
  local latest_version="$2"
  local sed_command="$3"

  case "$MODE" in
    "dry-run")
      echo -e "🧪 ${YELLOW}Dry-run:${NC} would update $service_name to $latest_version"
      ;;
    "auto-apply")
      if [[ $service_name == "mongo" ]]; then
        backup_mongo "mongo"
      fi
      if [[ $BACKED_UP == false ]]; then
        backup_file "$COMPOSE_FILE"
        BACKED_UP=true
      fi
      # Update the tag
      sed -i.bak -E "$sed_command" "$COMPOSE_FILE"
      echo -e "✔ Updated $service_name image tag to version $latest_version in $COMPOSE_FILE..."
      echo -e "${BLUE}🔄 Restarting $service_name with the $latest_version image...${NC}"
      sudo docker compose -f "$COMPOSE_FILE" up -d "$service_name"
      ;;
    *)
      read -p "❓ Update $service_name to $latest_version? (y/n): " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if [[ $service_name == "mongo" ]]; then
          backup_mongo "mongo"
        fi
        if [[ $BACKED_UP == false ]]; then
          backup_file "$COMPOSE_FILE"
          BACKED_UP=true
        fi
        # Update the tag
        sed -i.bak -E "$sed_command" "$COMPOSE_FILE"
        echo -e "✔ Updated $service_name image tag to version $latest_version in $COMPOSE_FILE..."
        echo -e "${BLUE}🔄 Restarting $service_name with the $latest_version image...${NC}"
        sudo docker compose -f "$COMPOSE_FILE" up -d "$service_name"
      else
        echo -e "⏭️ Skipped $service_name update."
      fi
      ;;
    esac
}

# Function to get the current compose tag
get_compose_tag() {
  local sed_command="$1"
  local current_tag=$(sed -n $sed_command "$COMPOSE_FILE" | xargs)
  echo "$current_tag"
}

# Function to update compose tag if they are set to 'latest' to allow rollback
replace_compose_tags() {
  local sed_command="$1"
  # Replace image tag
  sed -i.bak -E "$sed_command" "$COMPOSE_FILE"
}

# ========== Main update logic ==========
check_for_update() {
  local service_name="$1"

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}🔄 Container: $service_name${NC}"

  # Check if the container is running, if not start it
  if ! sudo docker ps --format '{{.Names}}' | grep -q "^$(get_container_name "$service_name")$"; then
    echo -e "${YELLOW}⚠️ $service_name does not exist or is not running.${NC}"
    echo -e "${BLUE}🔄 Attempting to start $service_name...${NC}"
    sudo docker compose -f "$COMPOSE_FILE" up -d "$service_name"
    echo "💤 Sleeping 10 seconds to let $service_name start in order to check its version directly..."
    sleep 10s
  fi

  # Fetch the current version directly from the running container
  CURRENT_VERSION=$(fetch_current_version "$service_name")
  if [[ -z "$CURRENT_VERSION" ]]; then
    echo -e "${RED}❌ Failed to fetch the current version for $service_name${NC}"
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
    LATEST_VERSION=$(echo "$release_notes" | fetch_latest_version "$service_name" || true)
  fi

  if [[ -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}❌ Failed to determine latest version for $service_name${NC}"
    exit 1
  fi

  # Update logic for each container: cloudflared, nginx, mongo, minio
  case "$service_name" in
      "cloudflared")
        sed_command="s|cloudflare/$service_name:[^[:space:]]+|cloudflare/$service_name:$LATEST_VERSION|"
        format="^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$"
        # Check if the current version is in the valid XXXX.XX.X XXXX.X.X format
        check_format "$service_name" "$CURRENT_VERSION" "^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$" "XXXX.XX.X"
        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$LATEST_VERSION${NC}"
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if [[ "$(get_compose_tag "$sed_command")" != "$format" ]]; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tags $sed_command
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
        check_format "$service_name" "$CURRENT_VERSION" $format "XX.XX.XX"
        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$LATEST_VERSION${NC}"
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if [[ "$(get_compose_tag "$sed_command")" != "$format" ]]; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tags $sed_command
          fi
        else
          echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_VERSION):${NC}"
          echo -e "${BLUE}🔗 https://nginx.org/en/CHANGES${NC}"
          prompt_to_update $service_name $LATEST_VERSION $sed_command
        fi
        ;;
      "mongo")
        check_format "$service_name" "$CURRENT_VERSION" "^[0-9]{1,2}\.[0-9]+\.[0-9]{1,2}$" "XX.X.XX"
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
          if [[ "$(get_compose_tag "/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$LATEST_SAME_MAJOR|")" != "^[0-9]{1,2}\.[0-9]+\.[0-9]{1,2}$" ]]; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tags "/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$LATEST_SAME_MAJOR|"
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
        sed_command="s|minio/minio:[^[:space:]]+|minio/minio:$LATEST_VERSION|"
        format="^RELEASE\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$"
        check_format "$service_name" "$CURRENT_VERSION" "^RELEASE\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$" "RELEASE.YYYY-MM-DDTHH-MM-SSZ"
        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$LATEST_VERSION${NC}"
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if [[ "$(get_compose_tag "$sed_command")" != "$format" ]]; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tags $sed_command
          fi
        else
          echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_VERSION):${NC}"
          echo -e "${BLUE}🔗 https://github.com/minio/minio/compare/${CURRENT_VERSION}...${LATEST_VERSION}${NC}"
          prompt_to_update "minio" $LATEST_VERSION "s|minio/minio:[^[:space:]]+|minio/minio:$LATEST_VERSION|"
        fi
        ;;
      *)
        echo -e "${RED}❌ Unsupported container: $service_name${NC}" >&2
        echo "Usage:"
        echo "./update_containers.sh [all|mongo|minio|nginx|cloudflared] [dry-run|auto-apply|interactive] [health]"
        echo "./update_containers.sh all"
        echo "./update_containers.sh cloudflared auto-apply"
        echo "./update_containers.sh nginx dry-run"
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
  echo -e "${BLUE}⚙️ Checking for non-RF container updates...${NC}"
  for container in "${CONTAINERS[@]}"; do
    check_for_update "$container"
  done
  echo -e "${GREEN}🚀 Done. Non-RF container update process complete.${NC}"
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