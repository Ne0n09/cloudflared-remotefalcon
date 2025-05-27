#!/bin/bash

# VERSION=2025.5.27.1

# This script will check for and display updates for the Remote Falcon containers using the commit hash from the GitHub repo.
# ./update_rf_containers.sh dry-run = Check for updates and show changelogs without applying any changes.
# ./update_containers.sh auto-apply = Check for updates and apply them automatically.
# ./update_containers.sh = Check for updates and prompt for confirmation before applying changes.
# Include 'health' as the second argument to run the health check script after updating.
# Usage: ./update_rf_containers.sh [dry-run|auto-apply|interactive] [health]

#set -euo pipefail

# ========== Config ==========
# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared_functions.sh"
MODE="${1:-}"  # Options: dry-run, auto-apply, or interactive
HEALTH_CHECK="${2:-}" # Options: health or empty
UPDATED=false # Flag to track if any updates were made during the run
BACKED_UP=false # Flag to track if a backup was made

if [[ -z "$MODE" ]]; then
  MODE="interactive"  # Default to interactive mode if not provided
fi

if [[ -z "$HEALTH_CHECK" ]]; then
  HEALTH_CHECK=false  # Default to false if not provided
fi

# Remote Falcon containers and their repos
CONTAINERS=(
  "external-api|https://github.com/Remote-Falcon/remote-falcon-external-api.git|main"
  "ui|https://github.com/Remote-Falcon/remote-falcon-ui.git|main"
  "plugins-api|https://github.com/Remote-Falcon/remote-falcon-plugins-api.git|main"
  "viewer|https://github.com/Remote-Falcon/remote-falcon-viewer.git|main"
  "control-panel|https://github.com/Remote-Falcon/remote-falcon-control-panel.git|main"
)

# ========== Functions ==========

# Updates the VERSION in the .env file so you can see the current version on the RF control panel
update_rf_version() {
  NEW_VERSION=$(date +'%Y.%m.%-d')
  if [[ -f "$ENV_FILE" ]]; then
    if grep -q "^VERSION=" "$ENV_FILE"; then
      sed -i "s/^VERSION=.*/VERSION=$NEW_VERSION/" "$ENV_FILE"
    else
      echo "VERSION=$NEW_VERSION" >> "$ENV_FILE"
    fi
  fi
}

# Updates the container image tag from the shortened commit hash and updates the build context hash in the compose.yaml
replace_compose_tags() {
  local container_name="$1"
  local short_hash="$2"
  local full_hash="$3"

  if [[ $BACKED_UP == false ]]; then
    # Backup the compose file if not already backed up
    backup_file "$COMPOSE_FILE"
    BACKED_UP=true
  fi

  # Replace image tag
  sed -i "s|image:.*$container_name:.*|image: $container_name:$short_hash|g" "$COMPOSE_FILE"

  # Update or insert build context hash, accounting for if there is no existing # or hash
  sed -i -E "s|(context: https://github.com/Remote-Falcon/remote-falcon-${container_name}\.git)(#.*)?|\1#$full_hash|g" "$COMPOSE_FILE"
  
  UPDATED=true
}

# Displays the changes from the current commit to the latest commit in the Remote Falcon repo along with a compare link
show_changelog() {
  local name="$1"
  local from_hash="$2"
  local to_hash="$3"
  local repo="$4"
  local branch="$5"

  local temp_dir
  temp_dir=$(mktemp -d)
  git clone --quiet --branch "$branch" "$repo" "$temp_dir" || return 1

  cd "$temp_dir" || return
  local diff_output
  if git merge-base --is-ancestor "$from_hash" "$to_hash" 2>/dev/null; then
    diff_output=$(git log --oneline "$from_hash..$to_hash")
  else
    echo -e "${YELLOW}⚠️ One of the commits (${from_hash:0:7} or ${to_hash:0:7}) is not found in history${NC}"
    cd - >/dev/null
    rm -rf "$temp_dir"
    return
  fi
  cd - >/dev/null
  rm -rf "$temp_dir"

  if [[ -n "$diff_output" ]]; then
    echo -e "${CYAN}📜 $name Changelog (${from_hash:0:7} → ${to_hash:0:7}):${NC}"
    echo -e "${BLUE}🔗 https://github.com/Remote-Falcon/remote-falcon-$name/compare/${from_hash}...${to_hash}${NC}"

    echo "$diff_output" | while read -r line; do
      echo -e "  ${YELLOW}•${NC} $line"
    done
  fi
}

# Run the update check for each container
run_updates() {
  local mode="$1"
  declare -A updates

  echo -e "${BLUE}⚙️ Checking for Remote Falcon container updates...${NC}"

  for entry in "${CONTAINERS[@]}"; do
  IFS='|' read -r container repo branch <<< "$entry"
  latest_hash=$(git ls-remote "$repo" "$branch" | awk '{print $1}')
  short_hash=${latest_hash:0:7}

  current_tag=$(sed -n "/$container:/,/image:/ s/image:.*:\(.*\)/\1/p" "$COMPOSE_FILE" | xargs)
  current_ctx=$(awk "/$container:/{found=1} found && /context:/ {
  if (match(\$0, /#([a-f0-9]{40})/, a)) print a[1];
  else print \"\";
  exit
  }" "$COMPOSE_FILE")

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}🔄 Container: $container${NC}"
  if [[ -z "$current_ctx" ]]; then
      echo -e "${YELLOW}⚠️ No context hash found for $container; assuming update is needed.${NC}"
      current_ctx="(none)"
      updates["$container"]="$short_hash|$latest_hash|$repo|$branch"
    elif [[ "$short_hash" != "$current_tag" || "$latest_hash" != "$current_ctx" ]]; then
      updates["$container"]="$short_hash|$latest_hash|$repo|$branch"
  fi

  echo -e "🔸 Current tag: ${YELLOW}$current_tag${NC} - Current commit: ${YELLOW}$current_ctx${NC}"
  echo -e "🔹 Latest tag: ${GREEN}$short_hash${NC} - Latest commit: ${GREEN}$latest_hash${NC}"

  if [[ "$short_hash" != "$current_tag" || "$latest_hash" != "$current_ctx" ]]; then
    if [[ "$current_ctx" == "(none)" ]]; then
      echo -e "${CYAN}📜 $container Changelog: (no previous context hash available)${NC}"
      echo -e "${BLUE}🔗 GitHub: ${BLUE}${repo%.git}/commits/$branch${NC}"
    else
      show_changelog "$container" "$current_ctx" "$latest_hash" "$repo" "$branch"
    fi

    case "$mode" in
      dry-run)
        echo -e "🧪 ${YELLOW}Dry-run:${NC} would update $container to $short_hash"
        ;;
      auto-apply)
    
        replace_compose_tags "$container" "$short_hash" "$latest_hash"
        ;;
      *)
        read -p "❓ Update $container to $short_hash? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          replace_compose_tags "$container" "$short_hash" "$latest_hash"
        else
          echo -e "⏭️ Skipped $container update."
        fi
        ;;
    esac
  else
    echo -e "${GREEN}✅ $container is up-to-date.${NC}"
  fi
done
}

# Finalize updates by building new images and restarting containers
finalize_compose() {
  local mode="$1"
  if [[ "$mode" == "dry-run" ]]; then
    echo -e "${YELLOW}⚠️ Dry-run mode: No changes will be applied.${NC}"
    return
  fi

  if [[ "$UPDATED" == true ]]; then
    echo -e "🛠️ ${BLUE}Building containers with updated tags...${NC}"
    update_rf_version
    sudo docker compose -f "$COMPOSE_FILE" build
    echo -e "${BLUE}🔄 Restarting containers with updated tags...${NC}"
    sudo docker compose -f "$COMPOSE_FILE" up -d
  fi
}

# ========== Run ==========
run_updates "$MODE"
finalize_compose "$MODE"
health_check "$HEALTH_CHECK"

echo -e "${GREEN}🚀 Done. Remote Falcon container update process complete.${NC}"
exit 0