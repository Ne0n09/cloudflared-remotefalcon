#!/bin/bash

# VERSION=2026.5.29.1

# This script will run the GitHub Actions workflow in the REPO configured in the .env to build: plugins-api, control-panel, viewer, ui, and external-api.
# It will call the unified build.yml workflow with inputs based on the arguments passed.
# It will also sync the latest values from the .env file to the GitHub repo secrets for the build ARGs before triggering the workflow.
# Usage:./run_workflow.sh [ container | container=sha | container=sha container=sha ...]
# ./run_workflow.sh =  Runs the build.yml GitHub Actions workflow to build all containers to the latest available commit.
# ./run_workflow.sh [container] = Runs the build.yml GitHub Actions workflow to build an individual container to the latest available commit on 'main'.
# ./run_workflow.sh [container=sha] = Runs the build.yml GitHub Actions workflow to build an individual container to a specific commit SHA.
# ./run_workflow.sh plugins-api=69c0c53 control-panel=671bbed viewer=060011d ui=245c529 external-api=f7e09fe = Runs the build.yml GitHub Actions workflow to build all containers to the specified commit SHAs.

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
WORKFLOW_FILE="build.yml"                   # Workflow filename in .github/workflows. This should be in the REPO specified in .env
DEFAULT_REF="main"                            # Default branch if none specified
CONTAINERS=("plugins-api" "control-panel" "viewer" "ui" "external-api")
POLL_INTERVAL=10  # Seconds between status checks on GitHub Actions run
COMPOSE_TAG_UPDATES=()


# Validate GitHub CLI and GHCR docker login are successful in order to build and pull images, these are in shared_functions.sh
validate_github_user "$GITHUB_PAT" || exit 1
validate_github_repo "$REPO" || exit 1
validate_docker_user || exit 1

# ========== Functions ==========
# Validate workflow file exists in the .github/workflows directory of the REPO
validate_workflow_file() {
  local repo="$1"
  local workflow_file="$2"

  if ! gh api -H "Accept: application/vnd.github+json" \
            "/repos/$repo/contents/.github/workflows/$workflow_file" \
            >/dev/null 2>&1; then
    echo -e "${RED}❌ ERROR: Workflow file '$workflow_file' does not exist in repo '$repo'.${NC}"
    return 1
  fi
  return 0
}

# From shared_functions.sh. Updates the VERSION in the .env file so you can see the current version on the RF control panel
update_rf_version

# Resolves a short SHA to a full 40-character SHA using GitHub API
get_full_sha() {
  local service_name="$1" # Specify one of the RF services: plugins-api, control-panel, viewer, ui, external-api
  local short_sha="$2"  # e.g. 7e994c0

  if [[ -z "$short_sha" ]]; then
    echo ""
    return 1
  fi

  # GitHub API endpoint for a specific commit in the Remote Falcon monorepo
  local api_url="https://api.github.com/repos/${REMOTE_FALCON_PLATFORM_REPO}/commits/$short_sha"

  # Fetch full SHA
  local full_sha
  full_sha=$(curl -s -H "Accept: application/vnd.github+json" \
                   "$api_url" | jq -r '.sha // empty')

  if [[ -z "$full_sha" ]]; then
    echo -e "${YELLOW}⚠️ Could not resolve full SHA for $short_sha in $REMOTE_FALCON_PLATFORM_REPO. Using $short_sha as-is.${NC}" >&2
    echo "$short_sha"
  else
    echo "$full_sha"
  fi
}

is_valid_container() {
  local service_name="$1"
  [[ " ${CONTAINERS[*]} " =~ " ${service_name} " ]]
}

queue_compose_tag_update() {
  local service_name="$1"
  local ref="$2"

  if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
    COMPOSE_TAG_UPDATES+=("$service_name=$ref")
  fi
}

apply_compose_tag_updates() {
  local update
  local service_name
  local ref

  if [[ ${#COMPOSE_TAG_UPDATES[@]} -eq 0 ]]; then
    return 0
  fi

  echo -e "${BLUE}📝 Updating compose.yaml tags for explicitly requested commits...${NC}"
  for update in "${COMPOSE_TAG_UPDATES[@]}"; do
    service_name="${update%%=*}"
    ref="${update#*=}"
    replace_compose_tag "$service_name" "$ref"
    echo -e "${GREEN}✔ ${service_name}:${ref:0:7}${NC}"
  done
}

wait_for_deployed_services() {
  local services=("$@")
  local attempts="${RF_DEPLOY_CHECK_ATTEMPTS:-60}"
  local delay="${RF_DEPLOY_CHECK_DELAY:-2}"
  local service health_status all_ready

  while (( attempts-- > 0 )); do
    all_ready=true
    for service in "${services[@]}"; do
      if ! docker compose -f "$COMPOSE_FILE" ps --services --filter status=running | grep -Fxq "$service"; then
        all_ready=false
        continue
      fi
      health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$service" 2>/dev/null || true)
      [[ "$health_status" == "starting" || "$health_status" == "unhealthy" ]] && all_ready=false
    done
    if [[ "$all_ready" == "true" ]]; then
      echo -e "${GREEN}✅ Newly built services passed their deployment checks.${NC}"
      return 0
    fi
    sleep "$delay"
  done

  echo -e "${RED}❌ One or more newly built services did not become ready.${NC}" >&2
  return 1
}

deploy_built_services() {
  local services=("$@") service image_id old_ref backup_tag
  local snapshot
  local -a previous_refs=() rollback_tags=()
  snapshot=$(mktemp) || return 1
  cp "$COMPOSE_FILE" "$snapshot" || { rm -f "$snapshot"; return 1; }

  # Save the currently running image, including same-tag rebuilds.
  for service in "${services[@]}"; do
    image_id=$(docker inspect --format '{{.Image}}' "$service" 2>/dev/null || true)
    old_ref=$(docker inspect --format '{{.Config.Image}}' "$service" 2>/dev/null || true)
    backup_tag="rf-rollback-${service}:$(date +%s)"
    if [[ -n "$image_id" && -n "$old_ref" ]] && docker image tag "$image_id" "$backup_tag"; then
      previous_refs+=("$old_ref")
      rollback_tags+=("$backup_tag")
    else
      previous_refs+=("")
      rollback_tags+=("")
    fi
  done

  update_compose_image_path
  apply_compose_tag_updates
  if ! docker compose -f "$COMPOSE_FILE" config -q ||
     ! docker compose -f "$COMPOSE_FILE" pull "${services[@]}"; then
    echo -e "${RED}❌ Image pull or Compose validation failed; deployment was not changed.${NC}" >&2
    cp "$snapshot" "$COMPOSE_FILE"
    rm -f "$snapshot"
    for backup_tag in "${rollback_tags[@]}"; do
      [[ -z "$backup_tag" ]] || docker image rm "$backup_tag" >/dev/null 2>&1 || true
    done
    return 1
  fi
  # Allow Compose to start declared dependencies such as MongoDB on a fresh
  # install. The complete public health check runs after configure-rf starts
  # and initializes the remaining infrastructure services.
  if docker compose -f "$COMPOSE_FILE" up -d --force-recreate "${services[@]}" &&
     wait_for_deployed_services "${services[@]}"; then
    rm -f "$snapshot"
    for backup_tag in "${rollback_tags[@]}"; do
      [[ -z "$backup_tag" ]] || docker image rm "$backup_tag" >/dev/null 2>&1 || true
    done
    return 0
  fi

  echo -e "${RED}❌ Deployment health check failed. Restoring prior Compose file and images.${NC}" >&2
  cp "$snapshot" "$COMPOSE_FILE"
  rm -f "$snapshot"
  for ((i=0; i<${#services[@]}; i++)); do
    if [[ -n "${rollback_tags[$i]}" ]]; then
      docker image tag "${rollback_tags[$i]}" "${previous_refs[$i]}" || true
    fi
  done
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate "${services[@]}" || true
  for backup_tag in "${rollback_tags[@]}"; do
    [[ -z "$backup_tag" ]] || docker image rm "$backup_tag" >/dev/null 2>&1 || true
  done
  return 1
}

trigger_workflow() {
  local service="$1"
  
  validate_workflow_file "$REPO" "$WORKFLOW_FILE" || return 1

  if [[ "$service" == "ALL_SERVICES" ]]; then
    shift
    local inputs=(-F "service=all" -F "ref=$DEFAULT_REF")
    local svc
    local sha
    for arg in "$@"; do
      if [[ "$arg" == *"="* ]]; then
        svc="${arg%%=*}"
        sha="${arg#*=}"
      else
        svc="$arg"
        sha="$DEFAULT_REF"
      fi
      [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] && sha=$(get_full_sha "$svc" "$sha")
      inputs+=(-F "$svc=$sha")
      [[ "$arg" == *"="* ]] && queue_compose_tag_update "$svc" "$sha"
    done
    echo -e "${BLUE}📤 Triggering workflow for ALL services → $REPO${NC}"
    gh workflow run "$WORKFLOW_FILE" -R "$REPO" "${inputs[@]}"
  else
    local ref="${2:-$DEFAULT_REF}" 
    [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]] && ref=$(get_full_sha "$service" "$ref")
    queue_compose_tag_update "$service" "$ref"
    echo -e "${BLUE}📤 Triggering workflow for service: $service → $REPO (ref: $ref)${NC}"
    gh workflow run "$WORKFLOW_FILE" -R "$REPO" -F "service=$service" -F "ref=$ref"
  fi

  # Get the most recent run for this workflow
  sleep 5
  run_id=$(gh run list -R "$REPO" --workflow "$WORKFLOW_FILE" --limit 1 --json databaseId -q '.[0].databaseId')
  run_url="https://github.com/$REPO/actions/runs/$run_id"

  if [[ -z "$run_url" ]]; then
    echo -e "${RED}❌ Failed to trigger workflow for $service.${NC}"
    return 1
  fi

  start_time=$(date +%s)

  # Print initial message
  echo -e "⏳ Workflow triggered: ${BLUE}🔗 https://github.com/$REPO/actions/runs/$run_id${NC}"
  echo -e "${YELLOW}⚠️ This may take up to 20 minutes. Waiting for completion...${NC}"
  echo "Status updates every ${POLL_INTERVAL} seconds..."

  line_count=0

  while true; do
    elapsed=$(( $(date +%s) - start_time ))
    formatted=$(printf "%02d:%02d:%02d" $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))

    # Get jobs
    jobs=$(gh run view "$run_id" -R "$REPO" --json jobs \
      -q '.jobs[] | {name: .name, status: .status, conclusion: .conclusion}')

    # Build job output
    job_output=""
    while IFS= read -r job; do
      name=$(jq -r '.name' <<<"$job")
      status=$(jq -r '.status' <<<"$job")
      conclusion=$(jq -r '.conclusion' <<<"$job")

      icon="❓"
      case "$status" in
        queued|waiting) icon="⏳" ;;
        in_progress) icon="🟡" ;;
        completed)
          case "$conclusion" in
            success) icon="✅" ;;
            failure) icon="❌" ;;
            cancelled) icon="🚫" ;;
            skipped) icon="⏭️" ;;
          esac
          ;;
      esac

      job_output+="$icon $name Status: ($status) Conclusion: ($conclusion)\n"
    done < <(jq -c '.' <<<"$jobs")

    # Count printed lines (elapsed line + jobs)
    new_line_count=$(( $(echo -e "$job_output" | wc -l) + 1 ))

    # Clear previously printed lines
    if [ "$line_count" -gt 0 ]; then
      for ((i=0;i<line_count;i++)); do
        tput cuu1   # move up
        tput el     # clear line
      done
    fi

    # Print updated status
    echo -e "${CYAN}⏱️ Elapsed: $formatted${NC}"
    echo -e "$job_output"

    line_count=$new_line_count

  # Check if any jobs are still running
  incomplete=$(gh run view "$run_id" -R "$REPO" --json jobs \
    -q '[.jobs[] | select(.status!="completed")] | length')

  if [ "$incomplete" -eq 0 ]; then
    # All jobs are completed, now check conclusions
    failed=$(gh run view "$run_id" -R "$REPO" --json jobs \
      -q '[.jobs[] | select(.conclusion!="success")] | length')

    if [ "$failed" -eq 0 ]; then
      echo -e "${GREEN}✅ Workflow finished successfully!${NC}"
      local deploy_services=("${CONTAINERS[@]}")
      if [[ "$service" != "ALL_SERVICES" ]]; then
        deploy_services=("$service")
      fi
      deploy_built_services "${deploy_services[@]}" || return 1
      exit 0
    else
      echo -e "${RED}❌ Workflow failed (some jobs did not succeed).${NC}"
      exit 1
    fi
  fi
  sleep ${POLL_INTERVAL:-30}
  done
}
# ========== Main Logic ==========
update_rf_version # Updates the VERSION in the .env file prior to updating the repo secrets

# Syncs the latest values from .env to the GitHub repo secrets
if ! bash "$SCRIPT_DIR/sync_repo_secrets.sh"; then
  echo -e "${RED}❌ Sync repo secrets did not complete successfully, aborting.${NC}"
  exit 1
fi

if [[ $# -eq 0 ]]; then
  trigger_workflow "ALL_SERVICES"
else
  for arg in "$@"; do
    if [[ "$arg" == *"="* ]]; then
      service="${arg%%=*}"
    else
      service="$arg"
    fi

    is_valid_container "$service" || {
      echo -e "${RED}❌ Invalid argument: $arg${NC}"
      exit 1
    }
  done

  if [[ $# -gt 1 ]]; then
    trigger_workflow "ALL_SERVICES" "$@"
  else
    if [[ "$1" == *"="* ]]; then
      service="${1%%=*}"
      sha="${1#*=}"
      trigger_workflow "$service" "$sha"
    else
      trigger_workflow "$1" "$DEFAULT_REF"
    fi
  fi
fi
