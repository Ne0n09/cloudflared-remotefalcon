#!/usr/bin/env bash

# VERSION=2026.9.26.1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=shared_functions.sh
source "$SCRIPT_DIR/shared_functions.sh"

check_compose_exists
check_env_exists
parse_env

echo -e "${CYAN}1/6 Validating the merged Remote Falcon configuration...${NC}"
rf_compose config -q

echo -e "${CYAN}2/6 Starting Versity Gateway alongside legacy object storage...${NC}"
rf_compose up -d versitygw

running_services="$(rf_compose ps --services --filter status=running)"
if grep -Fxq nginx <<< "$running_services"; then
  echo -e "${CYAN}3/6 Restarting NGINX to refresh service discovery...${NC}"
  rf_compose restart nginx
else
  echo -e "${CYAN}3/6 NGINX is not running; it will be started with the upgraded stack.${NC}"
fi

echo -e "${CYAN}4/6 Updating containers with per-service validation and rollback...${NC}"
"$SCRIPT_DIR/update_containers.sh" all auto-apply

echo -e "${CYAN}5/6 Initializing object storage and migrating legacy MinIO data...${NC}"
"$SCRIPT_DIR/versitygw_init.sh"

echo -e "${CYAN}6/6 Applying the current stack and running the complete health check...${NC}"
rf_compose up -d --remove-orphans
"$SCRIPT_DIR/health_check.sh" 0s

echo -e "${GREEN}✔ Remote Falcon upgrade completed successfully.${NC}"
