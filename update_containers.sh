#!/bin/bash

# VERSION=2026.9.29.5

# This script will check for and display updates for containers: cloudflared, nginx, mongo, versitygw, plugins-api, control-panel, viewwer, ui, and external-api.
# ./update_containers.sh all
# ./update_containers.sh cloudflared
# ./update_containers.sh nginx
# Include 'health' as the third argument to run the health check script after updating.
# Usage: ./update_containers.sh [all|mongo|versitygw|nginx|cloudflared|plugins-api|control-panel|viewer|ui|external-api] [dry-run|auto-apply|interactive] [health]

#set -euo pipefail
#set -x

# ========== Config ==========
# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/shared_functions.sh" ]]; then
  echo -e "${RED}❌ ERROR: shared_functions.sh does not exist in $SCRIPT_DIR.${NC}"
  exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared_functions.sh"

# REPO and GITHUB_PAT is pulled from .env via parse_env in shared_functions.sh
check_env_exists
parse_env

SERVICE_NAME="${1:-}" # Options: all, mongo, versitygw, nginx, cloudflared
MODE="${2:-}"  # Options: dry-run, auto-apply, or interactive, defaults to interactive if not provided
HEALTH_CHECK="${3:-}" # Options: health or empty
# CONTAINERS defines the order that the containers will be updated in if no name is provided
CONTAINERS=("mongo" "versitygw" "plugins-api" "control-panel" "viewer" "ui" "external-api" "nginx" "cloudflared" )
BACKED_UP=false # Flag to track if a backup was made
MONGO_NO_AVX_PIN_ACTIVE=false
REMOTE_FALCON_REPO="$REMOTE_FALCON_PLATFORM_REPO" # Main repo to compare sha

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
  local repository=$2
  local credentials_file
  local response curl_status

  if github_workflow_builds_configured && [[ "$repository" == "$REPO" ]]; then
    credentials_file=$(mktemp) || return 1
    chmod 600 "$credentials_file"
    printf 'machine ghcr.io login user password %s\n' "$GITHUB_PAT" > "$credentials_file"
    response=$(curl -s --netrc-file "$credentials_file" \
      "https://ghcr.io/token?scope=repository:${repository}/${image}:pull" -w "%{http_code}")
    curl_status=$?
    rm -f "$credentials_file"
  else
    # Public GHCR packages issue anonymous pull tokens.
    response=$(curl -s \
      "https://ghcr.io/token?scope=repository:${repository}/${image}:pull" -w "%{http_code}")
    curl_status=$?
  fi
  [[ $curl_status -eq 0 ]] || return "$curl_status"

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
  local repository

  repository=$(image_repository_for_service "$image")
  if [[ -z "$repository" ]]; then
    echo -e "${YELLOW}⚠️ $image is configured as a local build.${NC}"
    return 1
  fi

  # Get a short-lived token for this image
  local token
  token=$(get_token "$image" "$repository") || return 1

  # Query the manifest for the specific tag
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
  "https://ghcr.io/v2/${repository}/${image}/manifests/$tag")

  if [[ "$status" == "200" ]]; then
    echo -e "🐳 Image ghcr.io/${repository}/$image:${GREEN}$tag${NC} exists in GitHub Container Registry."
    return 0
  elif [[ "$status" == "404" ]]; then
    echo -e "${RED}❌ Image ghcr.io/${repository}/$image:$tag does not exist in GitHub Container Registry.${NC}"
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
    "versitygw")
      jq -r '.[0].tag_name'
      ;;
    plugins-api|control-panel|viewer|ui|external-api)
      local full_sha
      if [[ "${RF_IMAGE_TAG_MODE:-app}" == "platform" ]] ||
         { ! github_workflow_builds_configured && public_backend_images_supported; }; then
        # New builder images include shared libraries and use the full platform
        # commit as their tag. Enable this after installing the new workflow.
        full_sha=$(curl -fsSL "https://api.github.com/repos/${REMOTE_FALCON_REPO}/commits/main" | jq -r '.sha // empty')
      else
        # Preserve compatibility with images produced by the archived builder.
        full_sha=$(curl -fsSL "https://api.github.com/repos/${REMOTE_FALCON_REPO}/commits?sha=main&path=${REMOTE_FALCON_APPS_DIR}/${service_name}&per_page=1" | jq -r '.[0].sha // empty')
      fi
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
wait_for_service_deployment() {
  local service_name="$1"
  local attempts="${RF_DEPLOY_CHECK_ATTEMPTS:-60}"
  local delay="${RF_DEPLOY_CHECK_DELAY:-2}"
  local health_status=""
  local check_endpoints="${2-health}"
  local deadline=$((SECONDS + ${RF_DEPLOY_CHECK_TIMEOUT:-120}))

  while (( attempts-- > 0 && SECONDS < deadline )); do
    if rf_compose ps --services --filter status=running | grep -Fxq "$service_name"; then
      health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$service_name" 2>/dev/null || true)
      case "$health_status" in
        healthy|none|"")
          # Running alone is insufficient for images without a Docker HEALTHCHECK.
          # Fresh installs initialize storage and routing later in configure-rf.
          # Invoke once; endpoint retry/backoff belongs to health_check.sh.
          if [[ -z "$check_endpoints" ]] || HEALTH_MAX_RETRIES="${HEALTH_MAX_RETRIES:-25}" \
              HEALTH_ENDPOINT_TIMEOUT="${HEALTH_ENDPOINT_TIMEOUT:-120}" \
              "$HEALTH_CHECK_SCRIPT" 0s "$service_name"; then
            echo -e "${GREEN}✅ $service_name passed its deployment check.${NC}"
            return 0
          fi
          return 1
          ;;
        unhealthy)
          # A container can briefly report unhealthy while its process is still
          # initializing. Keep polling so startup probes get their full grace
          # period before rollback.
          ;;
      esac
    fi
    sleep "$delay"
  done

  echo -e "${RED}❌ $service_name did not become ready within the deployment timeout.${NC}" >&2
  return 1
}

prepare_service_image() {
  local service_name="$1"

  if service_uses_registry_image "$service_name"; then
    echo -e "${BLUE}⬇️ Pulling the published $service_name image...${NC}"
    rf_compose pull "$service_name"
  else
    echo -e "${BLUE}🔨 Building $service_name locally...${NC}"
    rf_compose build "$service_name"
  fi
}

preflight_public_backend_release() {
  local platform_sha short_sha service

  github_workflow_builds_configured && return 0
  public_backend_images_supported || return 0

  platform_sha=$(curl -fsSL "https://api.github.com/repos/${REMOTE_FALCON_REPO}/commits/main" | jq -r '.sha // empty')
  [[ "$platform_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo -e "${RED}❌ Could not resolve the current Remote Falcon platform commit.${NC}" >&2
    return 1
  }
  short_sha=${platform_sha:0:7}

  echo -e "${BLUE}🔍 Verifying the coordinated public backend release $short_sha...${NC}"
  for service in "${RF_BACKEND_SERVICES[@]}"; do
    if ! check_image_exists "$service" "$short_sha"; then
      echo -e "${RED}❌ Public backend release $short_sha is incomplete. No application containers were updated.${NC}" >&2
      return 1
    fi
  done
}

perform_update() {
  local service_name="$1"
  local latest_version="$2"
  local sed_command="$3"
  local previous_compose previous_image previous_ref rollback_tag=""

  previous_compose=$(mktemp) || return 1
  cp "$COMPOSE_FILE" "$previous_compose" || { rm -f "$previous_compose"; return 1; }
  previous_image=$(docker inspect --format '{{.Image}}' "$service_name" 2>/dev/null || true)
  previous_ref=$(docker inspect --format '{{.Config.Image}}' "$service_name" 2>/dev/null || true)
  if [[ -n "$previous_image" && -n "$previous_ref" ]]; then
    rollback_tag="rf-rollback-${service_name}:$(date +%s)"
    docker image tag "$previous_image" "$rollback_tag" || rollback_tag=""
  fi

  if [[ $service_name == "mongo" ]]; then
    backup_mongo "mongo"
  fi
  if [[ $BACKED_UP == false ]]; then
    backup_file "$COMPOSE_FILE"
    BACKED_UP=true
  fi

  update_compose_dockerfile_paths
  if ! ensure_service_runtime_environment "$service_name"; then
    cp "$previous_compose" "$COMPOSE_FILE"
    rm -f "$previous_compose"
    return 1
  fi

  case "$service_name" in
    plugins-api|control-panel|viewer|ui|external-api)
      # Update the build context line in compose.yaml to allow local builds from the correct commit
      update_rf_build_context "$service_name" "$latest_version"
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
  if rf_compose config -q &&
     prepare_service_image "$service_name" &&
     rf_compose up -d --no-deps "$service_name" &&
     wait_for_service_deployment "$service_name" "${previous_image:+health}"; then
    rm -f "$previous_compose"
    [[ -z "$rollback_tag" ]] || docker image rm "$rollback_tag" >/dev/null 2>&1 || true
    return 0
  fi
  echo -e "${RED}❌ $service_name failed its deployment check; restoring its previous image and Compose file.${NC}" >&2
  cp "$previous_compose" "$COMPOSE_FILE"
  rm -f "$previous_compose"
  if [[ -n "$rollback_tag" ]]; then
    docker image tag "$rollback_tag" "$previous_ref" || true
  fi
  rf_compose up -d --no-deps --force-recreate "$service_name" || true
  if ! wait_for_service_deployment "$service_name"; then
    echo "❌ Restored $service_name is still unhealthy; inspect its configuration and logs." >&2
  fi
  [[ -z "$rollback_tag" ]] || docker image rm "$rollback_tag" >/dev/null 2>&1 || true
  exit 1
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
        read -rp "❓ Update $service_name to ${latest_version:0:7}? (y/n) [n]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          perform_update "$service_name" "$latest_version" "$sed_command"
        else
          echo -e "⏭️ Skipped $service_name update."
        fi
        ;;
      *)
        read -rp "❓ Update $service_name to ${latest_version}? (y/n) [n]: " confirm
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
if [[ "$SERVICE_NAME" == "all" || "$SERVICE_NAME" =~ ^(plugins-api|control-panel|viewer|ui|external-api)$ ]]; then
  if [[ ! -z "$REPO" && ! "$REPO" == "username/repo" && "$REPO" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ && ! -z "$GITHUB_PAT" ]]; then
    validate_github_user "$GITHUB_PAT" || exit 1
    validate_github_repo "$REPO" || exit 1
    validate_docker_user || exit 1
  fi
  # Removes or adds ghcr.io/${REPO}/ prefix to the compose.yaml image paths based on the current $REPO value configured in the .env
  update_compose_image_path
fi

check_for_update() {
  local service_name="$1"
  CURRENT_VERSION=""
  LATEST_VERSION=""

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}📦 Container: $service_name${NC}"

  if [[ "$service_name" == "mongo" ]] && ! prepare_mongo_cpu_compatibility; then
    exit 1
  fi

  # Check if the container is NOT running, for non-RF containers start if not started to get version directly, for RF containers check compose.yaml for tag
  if ! is_container_running "$service_name"; then
    echo -e "${YELLOW}⚠️ $service_name does not exist or is not running.${NC}"
    case "$service_name" in
      cloudflared|nginx|mongo|versitygw)
        echo -e "${BLUE}🔄 Attempting to start $service_name to check its version directly...${NC}"
        rf_compose up -d "$service_name"
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
            #exit 1
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
    "versitygw")
      RELEASE_NOTES_URL="https://api.github.com/repos/versity/versitygw/releases"
      ;;
    plugins-api|control-panel|viewer|ui|external-api)
      RELEASE_NOTES_URL="https://github.com/${REMOTE_FALCON_REPO}/commits/main/${REMOTE_FALCON_APPS_DIR}/${service_name}"
      ;;
    *)
      echo -e "${RED}❌ Unsupported container: $service_name${NC}" >&2
      exit 1
      ;;
  esac

  # A non-AVX x86-64 host has a fixed MongoDB ceiling. Do not fetch or offer a
  # newer release for that host.
  if [[ "$service_name" == "mongo" && "$MONGO_NO_AVX_PIN_ACTIVE" == true ]]; then
    LATEST_VERSION="$MONGO_NO_AVX_VERSION"
  else
    # Fetch the release notes for the service from $RELEASE_NOTES_URL and store them in release_notes
    local release_notes
    release_notes=$(curl -s "$RELEASE_NOTES_URL" || true)
    if [[ -z "$release_notes" ]]; then
      echo -e "${RED}❌ Failed to fetch release notes for $service_name from $RELEASE_NOTES_URL${NC}"
    else
      # Fetch latest version(s) from the release notes
      LATEST_VERSION=$(echo "$release_notes" | get_latest_version "$service_name" || true)
    fi
  fi

  if [[ "$LATEST_VERSION" == "null" || -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}❌ Failed to determine latest version for $service_name. Try running update_containers.sh again. ${NC}"
    exit 1
  fi

  # Update logic for each container: cloudflared, nginx, mongo, versitygw, plugins-api, control-panel, viewer, ui, external-api
  case "$service_name" in
      "cloudflared")
        sed_command="s|cloudflare/$service_name:[^[:space:]]+|cloudflare/$service_name:$LATEST_VERSION|"
        # Check if the current version is in the valid XXXX.XX.X XXXX.X.X format
        check_tag_format "$service_name" "$CURRENT_VERSION"
        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$LATEST_VERSION${NC}"
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if ! check_tag_format "$service_name" "$(get_current_compose_tag "$service_name")"; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tag "$service_name" "$LATEST_VERSION"
          fi
        else
          echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_VERSION):${NC}"
          echo -e "${BLUE}🔗 https://github.com/cloudflare/cloudflared/compare/${CURRENT_VERSION}...${LATEST_VERSION}${NC}"
          prompt_to_update "$service_name" "$LATEST_VERSION" "s|cloudflare/$service_name:[^[:space:]]+|cloudflare/$service_name:$LATEST_VERSION|"
        fi
        ;;
      "nginx")
        sed_command="/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$LATEST_VERSION|"
        check_tag_format "$service_name" "$CURRENT_VERSION"
        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$LATEST_VERSION${NC}"
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if ! check_tag_format "$service_name" "$(get_current_compose_tag "$service_name")"; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tag "$service_name" "$LATEST_VERSION"
          fi
        else
          echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_VERSION):${NC}"
          echo -e "${BLUE}🔗 https://nginx.org/en/CHANGES${NC}"
          prompt_to_update "$service_name" "$LATEST_VERSION" "$sed_command"
        fi
        ;;
      "mongo")
        check_tag_format "$service_name" "$CURRENT_VERSION"
        if [[ "$MONGO_NO_AVX_PIN_ACTIVE" == true ]]; then
          echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
          echo -e "📌 CPU-compatible pinned version: ${GREEN}$MONGO_NO_AVX_VERSION${NC}"
          if [[ "$CURRENT_VERSION" == "$MONGO_NO_AVX_VERSION" ]]; then
            echo -e "${GREEN}✅ MongoDB is pinned at $MONGO_NO_AVX_VERSION because this CPU does not support AVX.${NC}"
            if [[ "$(get_current_compose_tag "$service_name")" != "$MONGO_NO_AVX_VERSION" ]]; then
              replace_compose_tag "$service_name" "$MONGO_NO_AVX_VERSION"
            fi
          else
            echo -e "${YELLOW}⚠️ MongoDB releases newer than $MONGO_NO_AVX_VERSION require AVX and will not be offered.${NC}"
            prompt_to_update "$service_name" "$MONGO_NO_AVX_VERSION" "/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$MONGO_NO_AVX_VERSION|"
          fi
          return 0
        fi
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
          if ! check_tag_format "$service_name" "$(get_current_compose_tag "$service_name")"; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tag "$service_name" "$LATEST_SAME_MAJOR"
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
            prompt_to_update "$service_name" "$LATEST_SAME_MAJOR" "/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$LATEST_SAME_MAJOR|"
          elif [[ -n "${LATEST_NEXT_MAJOR:-}" ]]; then
            if [[ "$MODE" == "auto-apply" ]]; then
              echo -e "${YELLOW}⚠️ A MongoDB major upgrade to $LATEST_NEXT_MAJOR is available but will not be applied automatically.${NC}"
              echo -e "${YELLOW}⚠️ Follow MongoDB's documented major-version upgrade path before changing this tag.${NC}"
              replace_compose_tag "$service_name" "$LATEST_SAME_MAJOR"
            else
              # Major upgrades can require intermediate versions and feature
              # compatibility changes, so they always require explicit input.
              echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_NEXT_MAJOR):${NC}"
              echo -e "${YELLOW}⚠️ See MongoDB release notes here to confirm upgrade paths:${NC}${BLUE}🔗 https://www.mongodb.com/docs/manual/release-notes/${NC}"
              prompt_to_update "$service_name" "$LATEST_NEXT_MAJOR" "/^\s*image:\s*$service_name:[^[:space:]]+/s|$service_name:[^[:space:]]+|$service_name:$LATEST_NEXT_MAJOR|"
            fi
          fi
        fi
        ;;
      "versitygw")
        sed_command="s|versity/versitygw:[^[:space:]]+|versity/versitygw:$LATEST_VERSION|"
        check_tag_format "$service_name" "$CURRENT_VERSION"
        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$LATEST_VERSION${NC}"
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if ! check_tag_format "$service_name" "$(get_current_compose_tag "$service_name")"; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tag "$service_name" "$LATEST_VERSION"
          fi
        else
          echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $LATEST_VERSION):${NC}"
          echo -e "${BLUE}🔗 https://github.com/versity/versitygw/compare/${CURRENT_VERSION}...${LATEST_VERSION}${NC}"
          prompt_to_update "versitygw" "$LATEST_VERSION" "$sed_command"
        fi
        ;;
      plugins-api|control-panel|viewer|ui|external-api)
        short_sha=${LATEST_VERSION:0:7}
        # This isn't used in perform_update since I had issues getting this to work correctly, so there is a case statement just for the RF images in perform_update
        sed_command="s|(^[[:space:]]*image:[[:space:]]*\"?)([^\"[:space:]]*${service_name}):[^\"[:space:]]+(\"?)|\1\2:${latest_version}\3|"
        check_tag_format "$service_name" "$CURRENT_VERSION"
        correct_format=$? # Capture the return value of check_tag_format

        # Start the container if it is not running and the compose.yaml format is correct(not 'latest')
        if (( correct_format == 0 )) && ! is_container_running "$service_name"; then
          echo -e "${BLUE}🔄 $service_name tag ${YELLOW}$CURRENT_VERSION${BLUE} is in valid format. Attempting to start $service_name...${NC}"
          rf_compose up -d "$service_name"
        fi

        echo -e "🔸 Current version: ${YELLOW}$CURRENT_VERSION${NC}"
        echo -e "🔹 Latest version: ${GREEN}$short_sha${NC}"

        if [[ "$CURRENT_VERSION" == "$short_sha" ]]; then
          echo -e "${GREEN}✅ $service_name is up-to-date.${NC}"
          if ! check_tag_format "$service_name" "$(get_current_compose_tag "$service_name")"; then
            # Update the tag in compose.yaml if it is not in the valid format
            replace_compose_tag "$service_name" "$LATEST_VERSION"
          fi
        else
          echo -e "${CYAN}📜 $service_name Changelog ($CURRENT_VERSION → $short_sha):${NC}"
          echo -e "${BLUE}🔗 https://github.com/${REMOTE_FALCON_REPO}/commits/main/${REMOTE_FALCON_APPS_DIR}/${service_name}${NC}"

          case "$MODE" in
            "dry-run")
              if ! service_uses_registry_image "$service_name"; then
                if (( correct_format == 0 )); then
                  echo -e "🧪 ${YELLOW}Dry-run:${NC} would locally build and update $service_name to $short_sha"
                else
                  echo -e "🧪 ${YELLOW}Dry-run:${NC} would re-tag $service_name and locally build and update $service_name to $short_sha"
                fi
              else
                if check_image_exists "$service_name" "$short_sha"; then
                  if (( correct_format == 0 )); then
                    echo -e "🧪 ${YELLOW}Dry-run:${NC} would update $service_name to $short_sha"
                  else
                    echo -e "🧪 ${YELLOW}Dry-run:${NC} would re-tag $service_name and update $service_name to $short_sha"
                  fi
                elif github_workflow_builds_configured; then
                  echo -e "🧪 ${YELLOW}Dry-run:${NC} would perform run_workflow.sh to build and push $service_name:$short_sha to $REPO"
                  echo -e "🧪 ${YELLOW}Dry-run:${NC} would update $service_name to $short_sha"
                else
                  echo -e "🧪 ${YELLOW}Dry-run:${NC} would wait for the public AMD64/ARM64 $service_name:$short_sha image to be published"
                fi
              fi
              ;;
            "auto-apply")
              if ! service_uses_registry_image "$service_name"; then
                update_rf_version # From shared_functions.sh
                perform_update "$service_name" "$LATEST_VERSION" "$sed_command" 
              else
                if check_image_exists "$service_name" "$short_sha"; then
                  perform_update "$service_name" "$LATEST_VERSION" "$sed_command" # $LATEST_VERSION will get converted to short sha in perform_update
                elif github_workflow_builds_configured; then
                  if bash "$SCRIPT_DIR/run_workflow.sh" "$service_name=$LATEST_VERSION"; then
                    perform_update "$service_name" "$LATEST_VERSION" "$sed_command"
                  else
                    echo -e "${RED}❌ GitHub workflow did not complete successfully for $service_name.${NC}"
                  fi
                else
                  echo -e "${RED}❌ Public AMD64/ARM64 image $service_name:$short_sha has not been published yet; leaving the current container unchanged.${NC}" >&2
                  exit 1
                fi
              fi
              ;;
            *)
              if ! service_uses_registry_image "$service_name"; then
                read -rp "❓ Would you like to build $service_name:$short_sha? (y/n) [n]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                  perform_update "$service_name" "$LATEST_VERSION" "$sed_command"
                else
                  echo -e "⏭️ Skipped building $service_name."
                fi
              else
                if check_image_exists "$service_name" "$short_sha"; then
                  read -rp "❓ Update $service_name to ${short_sha}? (y/n) [n]: " confirm
                  if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    perform_update "$service_name" "$LATEST_VERSION" "$sed_command" # $LATEST_VERSION will get converted to short sha in perform_update
                  fi
                elif github_workflow_builds_configured; then
                  read -rp "❓ Would you like to build and push $service_name:$short_sha to repository $REPO with run_workflow.sh? (y/n) [n]: " confirm
                  if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    if bash "$SCRIPT_DIR/run_workflow.sh" "$service_name=$LATEST_VERSION"; then
                      perform_update "$service_name" "$LATEST_VERSION" "$sed_command" # $LATEST_VERSION will get converted to short sha in perform_update
                    else
                      echo -e "${RED}❌ GitHub workflow did not complete successfully for $service_name.${NC}"
                    fi
                  else
                    echo -e "⏭️ Skipped building $service_name."
                  fi
                else
                  echo -e "${YELLOW}⚠️ Public AMD64/ARM64 image $service_name:$short_sha has not been published yet; skipping it.${NC}"
                fi
              fi
              ;;
          esac
        fi
        ;;
      *)
        echo -e "${RED}❌ Unsupported container: $service_name${NC}" >&2
        echo "Usage:"
        echo "./update_containers.sh [all|mongo|versitygw|nginx|cloudflared|plugins-api|control-panel|viewer|ui|external-api] [dry-run|auto-apply|interactive] [health]"
        echo "./update_containers.sh all"
        echo "./update_containers.sh cloudflared auto-apply"
        echo "./update_containers.sh external-api dry-run"
        echo "./update_containers.sh mongo"
        echo "./update_containers.sh versitygw auto-apply health"
        exit 1
        ;;
  esac
}

# Check if the compose file exists
check_compose_exists
# If script is run with 'all', loop through all containers by calling the check_for_update function otherwise just check the specified container
if [ "$SERVICE_NAME" == "all" ]; then
  echo -e "${BLUE}⚙️ Checking for container updates...${NC}"
  preflight_public_backend_release || exit 1
  for container in "${CONTAINERS[@]}"; do
    check_for_update "$container"
    if [[ "$container" == "mongo" && "$MODE" != "dry-run" ]]; then
      mongo_init || exit 1
    fi
  done
  echo -e "${GREEN}🚀 Done. Container update process complete.${NC}"
else # If a specific container is provided, check for updates for that container and auto-apply or prompt for confirmation or dry-run
  # Validate the container name
  if [[ ! " ${CONTAINERS[*]} " =~ $SERVICE_NAME ]]; then
    echo -e "${RED}❌ Error: Unknown container '$SERVICE_NAME'. Valid options are: all ${CONTAINERS[*]}${NC}"
  else
    check_for_update "$SERVICE_NAME"
    if [[ "$SERVICE_NAME" == "mongo" && "$MODE" != "dry-run" ]]; then
      mongo_init || exit 1
    fi
  fi
fi

# Each changed service was checked during deployment, including rollback.
# Keep accepting the legacy third argument without checking unrelated services.
exit 0
