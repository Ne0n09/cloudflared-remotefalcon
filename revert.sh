#!/bin/bash

# VERSION=2025.6.6.1

#set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared_functions.sh"

echo -e "🔁 ${RED}Remote Falcon${NC} ${CYAN}Revert Utility${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "What would you like to revert?"
echo -e "  ${YELLOW}1${NC}) ⚙️ .env file"
echo -e "  ${YELLOW}2${NC}) 🧱 compose.yaml"
echo -e "  ${YELLOW}3${NC}) 🗃️ MongoDB database"
echo -ne "${CYAN}Select an option [1-3]: ${NC}"
read -r option

timestamp=$(date +'%Y-%m-%d_%H-%M-%S')

revert_file() {
  local file_type="$1"
  local backup_pattern="$2"
  local target_path="$3"
  local filename=$(basename "$target_path")

  echo -e "${CYAN}📂 Available backups for ${file_type}:${NC}"
  select file in "$BACKUP_DIR"/$backup_pattern; do
    if [[ -n "$file" && -f "$file" ]]; then
      echo -e "${YELLOW}⚠️ Backing up current ${file_type} as $filename.revert_back-$timestamp${NC}"
      cp "$target_path" "$BACKUP_DIR/$filename.revert_back-$timestamp"
      echo -e "${GREEN}✅ Restoring backup: $file${NC}"
      cp "$file" "$target_path"
      echo -e "${GREEN}🚀 Restarting containers...${NC}"
      sudo docker compose -f "$COMPOSE_FILE" up -d
      echo -e "${GREEN}✅ Revert completed.${NC}"
      break
    else
      echo -e "${RED}❌ Invalid selection. Try again or press Ctrl+C to exit.${NC}"
    fi
  done
}

revert_mongo() {
  echo -e "${CYAN}📂 Available MongoDB backups:${NC}"
  select file in "$BACKUP_DIR"/mongo_remote-falcon_backup_*.gz; do
    if [[ -n "$file" && -f "$file" ]]; then
      echo -e "${YELLOW}⚠️  Restoring MongoDB from: $file${NC}"
      sudo docker exec mongo sh -c "mongorestore --gzip --archive=/tmp/backup.gz --drop"
      sudo docker cp "$file" mongo:/tmp/backup.gz
      echo -e "${GREEN}✅ MongoDB restored from backup.${NC}"
      break
    else
      echo -e "${RED}❌ Invalid selection. Try again.${NC}"
    fi
  done
}

case "$option" in
  1)
    revert_file ".env" ".env.*" "$ENV_FILE"
    ;;
  2)
    revert_file "compose.yaml" "compose.yaml.*" "$COMPOSE_FILE"
    ;;
  3)
    revert_mongo
    ;;
  *)
    echo -e "${RED}❌ Invalid option. Exiting.${NC}"
    exit 1
    ;;
esac
