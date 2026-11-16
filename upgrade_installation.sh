#!/usr/bin/env bash

# VERSION=2026.11.16.2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REBUILD_MARKER="$SCRIPT_DIR/.rf-platform-rebuild-required"
APPLICATION_SERVICES=(plugins-api control-panel viewer ui external-api)
BACKEND_SERVICES=(plugins-api control-panel viewer external-api)
PRIVATE_BUILDER_WORKFLOWS=(build.yml build-all.yml build-container.yml)
DISABLED_PRIVATE_WORKFLOWS=()
MIGRATION_ACTIVE=false
MIGRATION_PRIVATE_REPO=""
MIGRATION_ENV_SNAPSHOT=""
MIGRATION_COMPOSE_SNAPSHOT=""
MIGRATION_APPLICATION_RECREATE_ATTEMPTED=false

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

resolve_platform_sha() {
  local platform_sha
  platform_sha=$(get_platform_sha)
  [[ "$platform_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo -e "${RED}❌ Could not resolve the current Remote Falcon platform commit.${NC}" >&2
    return 1
  }
  printf '%s\n' "$platform_sha"
}

private_builder_migration_requested() {
  local answer=""

  case "${RF_MIGRATE_PUBLIC_IMAGES:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    0|false|FALSE|no|NO) return 1 ;;
    "") ;;
    *)
      echo "RF_MIGRATE_PUBLIC_IMAGES must be true or false." >&2
      return 2
      ;;
  esac

  if [[ ! -t 0 ]]; then
    echo -e "${YELLOW}⚠️ Private image-builder settings were retained because this upgrade is non-interactive.${NC}"
    echo "Set RF_MIGRATE_PUBLIC_IMAGES=true when rerunning the upgrade to migrate automatically."
    return 1
  fi

  echo
  echo "This AMD64/ARM64 installation can use the four public backend images."
  echo "The deployment-specific UI will continue to be built locally."
  echo "Migration disables the scheduled private image-builder workflows and removes its REPO and GITHUB_PAT settings."
  read -r -p "Migrate to public backend images now? [Y/n] " answer || return 1
  [[ -z "$answer" || "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

disable_private_builder_workflows() {
  local repo="$1" workflow_path workflow state workflow_list

  validate_github_user "$GITHUB_PAT" || return 1
  validate_github_repo "$repo" || return 1
  DISABLED_PRIVATE_WORKFLOWS=()
  workflow_list=$(mktemp) || return 1

  if ! gh api --paginate "repos/$repo/actions/workflows" --jq \
      '.workflows[] | select(.path == ".github/workflows/build.yml" or .path == ".github/workflows/build-all.yml" or .path == ".github/workflows/build-container.yml") | [.path, .state] | @tsv' \
      > "$workflow_list"; then
    echo -e "${RED}❌ Could not inspect the private image-builder workflows in $repo.${NC}" >&2
    rm -f "$workflow_list"
    return 1
  fi

  while IFS=$'\t' read -r workflow_path state; do
    workflow="${workflow_path##*/}"
    [[ " ${PRIVATE_BUILDER_WORKFLOWS[*]} " == *" $workflow "* ]] || continue
    [[ "$state" == "active" ]] || continue
    gh api --method PUT "repos/$repo/actions/workflows/$workflow/disable" >/dev/null || {
      echo -e "${RED}❌ Could not disable $workflow in $repo.${NC}" >&2
      rm -f "$workflow_list"
      restore_private_builder_workflows "$repo"
      return 1
    }
    DISABLED_PRIVATE_WORKFLOWS+=("$workflow")
    echo -e "${GREEN}✔ Disabled the private $workflow workflow in $repo.${NC}"
  done < "$workflow_list"
  rm -f "$workflow_list"
}

restore_private_builder_workflows() {
  local repo="$1" workflow

  for workflow in "${DISABLED_PRIVATE_WORKFLOWS[@]}"; do
    if gh api --method PUT "repos/$repo/actions/workflows/$workflow/enable" >/dev/null; then
      echo -e "${YELLOW}Restored the private $workflow workflow after the failed migration.${NC}"
    else
      echo -e "${RED}❌ Could not re-enable $workflow in $repo. Re-enable it manually in GitHub Actions.${NC}" >&2
    fi
  done
  DISABLED_PRIVATE_WORKFLOWS=()
}

write_public_image_configuration() {
  local candidate
  candidate=$(mktemp) || return 1

  if ! awk '
    BEGIN {
      updates["REPO"]="username/repo"
      updates["GITHUB_PAT"]=""
      updates["RF_IMAGE_TAG_MODE"]="platform"
      updates["DOCKERFILE"]="Dockerfile.dev"
    }
    $0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/ {
      key=$0
      sub(/=.*/, "", key)
      if (key in updates) {
        print key "=" updates[key]
        written[key]=1
        next
      }
    }
    { print }
    END {
      for (key in updates) if (!(key in written)) print key "=" updates[key]
    }
  ' "$ENV_FILE" > "$candidate"; then
    rm -f "$candidate"
    return 1
  fi

  if ! env -u REPO -u GITHUB_PAT -u RF_IMAGE_TAG_MODE -u DOCKERFILE \
      docker compose -f "$COMPOSE_FILE" --env-file "$candidate" config -q; then
    echo -e "${RED}❌ Docker Compose rejected the public-image configuration.${NC}" >&2
    rm -f "$candidate"
    return 1
  fi
  mv -f "$candidate" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  parse_env
}

migrate_private_builder_to_public_images() {
  local platform_sha="$1" private_repo="$REPO"

  # Fail before disabling workflows or changing configuration when Proxmox (or
  # another hypervisor) has ballooned the guest below the UI build minimum.
  check_ui_build_memory || return 1

  MIGRATION_ENV_SNAPSHOT=$(mktemp) || return 1
  MIGRATION_COMPOSE_SNAPSHOT=$(mktemp) || { rm -f "$MIGRATION_ENV_SNAPSHOT"; return 1; }
  cp "$ENV_FILE" "$MIGRATION_ENV_SNAPSHOT"
  cp "$COMPOSE_FILE" "$MIGRATION_COMPOSE_SNAPSHOT"
  MIGRATION_PRIVATE_REPO="$private_repo"
  MIGRATION_APPLICATION_RECREATE_ATTEMPTED=false
  MIGRATION_ACTIVE=true
  trap handle_migration_interrupt INT TERM

  if disable_private_builder_workflows "$private_repo" &&
     write_public_image_configuration &&
     rebuild_all_application_images "$platform_sha" migration; then
    trap - INT TERM
    rm -f "$MIGRATION_ENV_SNAPSHOT" "$MIGRATION_COMPOSE_SNAPSHOT"
    MIGRATION_ACTIVE=false
    echo -e "${GREEN}✔ Migrated to public backend images. The UI remains a local build.${NC}"
    return 0
  fi

  echo -e "${RED}❌ Public-image migration failed. Restoring the private-builder configuration.${NC}" >&2
  restore_private_builder_migration
  return 1
}

restore_private_builder_migration() {
  [[ "$MIGRATION_ACTIVE" == true ]] || return 0
  trap '' INT TERM

  cp "$MIGRATION_ENV_SNAPSHOT" "$ENV_FILE"
  cp "$MIGRATION_COMPOSE_SNAPSHOT" "$COMPOSE_FILE"
  chmod 600 "$ENV_FILE"
  parse_env
  restore_private_builder_workflows "$MIGRATION_PRIVATE_REPO"

  # A pull or build failure never changed the running containers. Only restore
  # containers if the coordinated recreation had actually begun, and never
  # permit rollback to start a local build.
  if [[ "$MIGRATION_APPLICATION_RECREATE_ATTEMPTED" == true ]]; then
    rf_compose up -d --no-build --force-recreate "${APPLICATION_SERVICES[@]}" || true
  fi

  rm -f "$MIGRATION_ENV_SNAPSHOT" "$MIGRATION_COMPOSE_SNAPSHOT"
  MIGRATION_ACTIVE=false
  trap - INT TERM
}

handle_migration_interrupt() {
  echo >&2
  echo -e "${YELLOW}Migration interrupted. Restoring the private-builder configuration before exiting.${NC}" >&2
  restore_private_builder_migration
  exit 130
}

rebuild_all_application_images() {
  local platform_sha="$1" rollback_owner="${2:-self}" snapshot service
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
    check_ui_build_memory || return 1
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
       rf_compose build ui; then
      [[ "$rollback_owner" != migration ]] || MIGRATION_APPLICATION_RECREATE_ATTEMPTED=true
      if rf_compose up -d --force-recreate "${APPLICATION_SERVICES[@]}"; then
        rm -f "$snapshot"
        return 0
      fi
    fi
  elif rf_compose config -q &&
       rf_compose build "${APPLICATION_SERVICES[@]}" &&
       rf_compose up -d --force-recreate "${APPLICATION_SERVICES[@]}"; then
    rm -f "$snapshot"
    return 0
  fi

  if [[ "$rollback_owner" != migration ]]; then
    echo -e "${RED}❌ Batch application rebuild failed. Restoring the previous Compose configuration and application containers.${NC}" >&2
    cp "$snapshot" "$COMPOSE_FILE"
    rf_compose up -d --no-build --force-recreate "${APPLICATION_SERVICES[@]}" || true
  else
    echo -e "${RED}❌ Batch application preparation failed. Migration rollback will restore the private-builder configuration.${NC}" >&2
  fi
  rm -f "$snapshot"
  return 1
}

echo -e "${CYAN}1/8 Validating the merged Remote Falcon configuration...${NC}"
rf_compose config -q

echo -e "${CYAN}2/8 Migrating MongoDB credentials before application containers are rebuilt...${NC}"
mongo_init

echo -e "${CYAN}3/8 Checking whether the legacy application images require a coordinated rebuild...${NC}"
if github_workflow_builds_configured && public_backend_images_supported; then
  migration_status=0
  private_builder_migration_requested || migration_status=$?
  if [[ "$migration_status" -eq 0 ]]; then
    platform_sha=$(resolve_platform_sha)
    migrate_private_builder_to_public_images "$platform_sha"
    rm -f "$PLATFORM_REBUILD_MARKER"
  elif [[ "$migration_status" -eq 1 && -f "$PLATFORM_REBUILD_MARKER" ]]; then
    platform_sha=$(resolve_platform_sha)
    rebuild_all_application_images "$platform_sha"
    rm -f "$PLATFORM_REBUILD_MARKER"
  elif [[ "$migration_status" -eq 1 ]]; then
    echo -e "${GREEN}✔ Platform image migration was previously completed; the private-builder override was retained.${NC}"
  else
    exit "$migration_status"
  fi
elif [[ -f "$PLATFORM_REBUILD_MARKER" ]]; then
  platform_sha=$(resolve_platform_sha)
  rebuild_all_application_images "$platform_sha"
  rm -f "$PLATFORM_REBUILD_MARKER"
else
  echo -e "${GREEN}✔ Platform image migration has already been completed.${NC}"
fi

echo -e "${CYAN}4/8 Starting Versity Gateway alongside legacy object storage...${NC}"
rf_compose up -d versitygw

running_services="$(rf_compose ps --services --filter status=running)"
if grep -Fxq nginx <<< "$running_services"; then
  echo -e "${CYAN}5/8 Restarting NGINX to refresh service discovery...${NC}"
  rf_compose restart nginx
else
  echo -e "${CYAN}5/8 NGINX is not running; it will be started with the upgraded stack.${NC}"
fi

echo -e "${CYAN}6/8 Updating infrastructure containers and any remaining application changes...${NC}"
"$SCRIPT_DIR/update_containers.sh" all auto-apply

echo -e "${CYAN}7/8 Initializing and verifying object storage, then migrating legacy MinIO data...${NC}"
"$SCRIPT_DIR/versitygw_init.sh"

echo -e "${CYAN}8/8 Applying the current stack and running the complete health check...${NC}"
rf_compose up -d --remove-orphans
"$SCRIPT_DIR/health_check.sh" 0s

echo -e "${GREEN}✔ Remote Falcon upgrade completed successfully.${NC}"
if [[ "${RF_DOCKER_GROUP_ADDED:-false}" == true ]]; then
  echo "Docker group access was added for your account."
  echo "Run 'newgrp docker' now in the SSH session that launched this upgrade so future Docker commands work without sudo."
fi
