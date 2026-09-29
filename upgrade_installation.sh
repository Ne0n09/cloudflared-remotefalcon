#!/usr/bin/env bash

# VERSION=2026.9.29.1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REBUILD_MARKER="$SCRIPT_DIR/.rf-platform-rebuild-required"
APPLICATION_SERVICES=(plugins-api control-panel viewer ui external-api)
BACKEND_SERVICES=(plugins-api control-panel viewer external-api)

ensure_jq_installed() {
  command -v jq >/dev/null 2>&1 && return 0

  echo "jq is not installed. Attempting to install it..."
  local -a privilege=()
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || {
      echo "jq is required, but sudo is not installed. Install jq and rerun the upgrade." >&2
      return 1
    }
    privilege=(sudo)
  fi

  if command -v apt-get >/dev/null 2>&1; then
    if ! "${privilege[@]}" apt-get update || ! "${privilege[@]}" apt-get install -y jq; then
      echo "jq installation failed. Install jq and rerun the upgrade." >&2
      return 1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if ! "${privilege[@]}" dnf install -y jq; then
      echo "jq installation failed. Install jq and rerun the upgrade." >&2
      return 1
    fi
  elif command -v yum >/dev/null 2>&1; then
    if ! "${privilege[@]}" yum install -y jq; then
      echo "jq installation failed. Install jq and rerun the upgrade." >&2
      return 1
    fi
  elif command -v apk >/dev/null 2>&1; then
    if ! "${privilege[@]}" apk add jq; then
      echo "jq installation failed. Install jq and rerun the upgrade." >&2
      return 1
    fi
  else
    echo "jq is required, but no supported package manager was found. Install jq and rerun the upgrade." >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "jq installation failed. Install jq and rerun the upgrade." >&2
    return 1
  }
  echo "jq installation complete."
}

ensure_jq_installed

# shellcheck source=shared_functions.sh
source "$SCRIPT_DIR/shared_functions.sh"

check_compose_exists
check_env_exists
parse_env

get_platform_sha() {
  if [[ -n "${RF_PLATFORM_SHA_OVERRIDE:-}" ]]; then
    printf '%s\n' "$RF_PLATFORM_SHA_OVERRIDE"
    return
  fi
  curl -fsSL "https://api.github.com/repos/${REMOTE_FALCON_PLATFORM_REPO}/commits/main" |
    jq -r '.sha // empty'
}

rebuild_all_application_images() {
  local platform_sha="$1" snapshot service
  local -a workflow_args=()

  if [[ -n "${REPO:-}" && "$REPO" != "username/repo" &&
        "$REPO" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ && -n "${GITHUB_PAT:-}" ]]; then
    for service in "${APPLICATION_SERVICES[@]}"; do
      workflow_args+=("$service=$platform_sha")
    done
    echo -e "${CYAN}Updating the remote image-builder workflow and rebuilding all application images in one workflow...${NC}"
    "$SCRIPT_DIR/run_workflow.sh" "${workflow_args[@]}"
    return
  fi

  if public_backend_images_supported; then
    echo -e "${CYAN}Pulling the coordinated public AMD64/ARM64 backends and building the deployment-specific UI...${NC}"
  else
    echo -e "${CYAN}Building all application images locally because public images target AMD64 and ARM64 only...${NC}"
  fi
  snapshot=$(mktemp) || return 1
  cp "$COMPOSE_FILE" "$snapshot" || { rm -f "$snapshot"; return 1; }
  for service in "${APPLICATION_SERVICES[@]}"; do
    replace_compose_tag "$service" "$platform_sha"
  done
  update_compose_image_path

  if public_backend_images_supported; then
    if rf_compose config -q &&
       rf_compose pull "${BACKEND_SERVICES[@]}" &&
       rf_compose build ui &&
       rf_compose up -d --force-recreate "${APPLICATION_SERVICES[@]}"; then
      rm -f "$snapshot"
      return 0
    fi
  elif rf_compose config -q &&
       rf_compose build "${APPLICATION_SERVICES[@]}" &&
       rf_compose up -d --force-recreate "${APPLICATION_SERVICES[@]}"; then
    rm -f "$snapshot"
    return 0
  fi

  echo -e "${RED}❌ Batch application rebuild failed. Restoring the previous Compose configuration and application containers.${NC}" >&2
  cp "$snapshot" "$COMPOSE_FILE"
  rm -f "$snapshot"
  rf_compose up -d --force-recreate "${APPLICATION_SERVICES[@]}" || true
  return 1
}

echo -e "${CYAN}1/7 Validating the merged Remote Falcon configuration...${NC}"
rf_compose config -q

echo -e "${CYAN}2/7 Checking whether the legacy application images require a coordinated rebuild...${NC}"
if [[ -f "$PLATFORM_REBUILD_MARKER" ]]; then
  platform_sha=$(get_platform_sha)
  [[ "$platform_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo -e "${RED}❌ Could not resolve the current Remote Falcon platform commit.${NC}" >&2
    exit 1
  }
  rebuild_all_application_images "$platform_sha"
  rm -f "$PLATFORM_REBUILD_MARKER"
else
  echo -e "${GREEN}✔ Platform image migration has already been completed.${NC}"
fi

echo -e "${CYAN}3/7 Starting Versity Gateway alongside legacy object storage...${NC}"
rf_compose up -d versitygw

running_services="$(rf_compose ps --services --filter status=running)"
if grep -Fxq nginx <<< "$running_services"; then
  echo -e "${CYAN}4/7 Restarting NGINX to refresh service discovery...${NC}"
  rf_compose restart nginx
else
  echo -e "${CYAN}4/7 NGINX is not running; it will be started with the upgraded stack.${NC}"
fi

echo -e "${CYAN}5/7 Updating infrastructure containers and any remaining application changes...${NC}"
"$SCRIPT_DIR/update_containers.sh" all auto-apply

echo -e "${CYAN}6/7 Initializing and verifying object storage, then migrating legacy MinIO data...${NC}"
"$SCRIPT_DIR/versitygw_init.sh"

echo -e "${CYAN}7/7 Applying the current stack and running the complete health check...${NC}"
rf_compose up -d --remove-orphans
"$SCRIPT_DIR/health_check.sh" 0s

echo -e "${GREEN}✔ Remote Falcon upgrade completed successfully.${NC}"
if [[ "${RF_DOCKER_GROUP_ADDED:-false}" == true ]]; then
  echo "Docker group access was added for your account."
  echo "Run 'newgrp docker' now in the SSH session that launched this upgrade so future Docker commands work without sudo."
fi
