#!/bin/bash

# VERSION=2025.10.13.1

# This script will sync your build ARG secrets from the .env to the REPO defined in the .env file.
# These secrets are used during the build workflows.

#set -euo pipefail

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

# Validate the REPO variable is set to a non-default value in the correct format
if [[ -z "$REPO" || "$REPO" == "username/repo" ]]; then
    echo -e "${RED}❌ Repository is not in the correct format (username/repo).${NC}"
    exit 1
elif [[ ! "$REPO" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]]; then
  echo -e "${RED}❌ Repository is not in the correct format (username/repo).${NC}"
  exit 1
fi

# ARGs/Keys to sync from .env before running the workflow.
SYNC_KEYS=(
  "HOST_ENV"
  "VERSION"
  "CONTROL_PANEL_API"
  "VIEWER_API"
  "VIEWER_JWT_KEY"
  "GOOGLE_MAPS_KEY"
  "PUBLIC_POSTHOG_KEY"
  "PUBLIC_POSTHOG_HOST"
  "GA_TRACKING_ID"
  "MIXPANEL_KEY"
  "HOSTNAME_PARTS"
  "SOCIAL_META"
  "SWAP_CP"
  "VIEWER_PAGE_SUBDOMAIN"
  "OTEL_OPTS"
  "OTEL_URI"
  "MONGO_URI"
  "CLARITY_PROJECT_ID"
)

# Ensures the latest values from .env are synced to the GitHub repo secrets before triggering the workflow
sync_repo_secrets() {
  echo -e "${BLUE}🔄 Syncing secrets from $ENV_FILE to GitHub repo $REPO...${NC}"
    for key in "${SYNC_KEYS[@]}"; do
    raw_value="${!key:-}"

    # Expand embedded env variables like ${MONGO_INITDB_ROOT_USERNAME}
    value=$(echo "$raw_value" | envsubst)

    # Handle special dynamic substitutions
    if [[ "$key" == "CONTROL_PANEL_API" ]]; then
      value="https://${DOMAIN}/remote-falcon-control-panel"
    elif [[ "$key" == "VIEWER_API" ]]; then
      value="https://${DOMAIN}/remote-falcon-viewer"
    elif [[ "$key" == "MONGO_URI" ]]; then
      value="mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@mongo:27017/remote-falcon?authSource=admin"
    fi

    if [[ -n "$value" ]]; then
      echo -n "$value" | gh secret set "$key" -R "$REPO"
    fi
  done
  echo -e "${GREEN}✅ Secrets in GitHub repo $REPO are now synced with $ENV_FILE${NC}"
}

sync_repo_secrets