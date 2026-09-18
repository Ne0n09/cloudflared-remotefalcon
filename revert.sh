#!/bin/bash

# VERSION=2025.6.9.1

#set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared_functions.sh"
parse_env $ENV_FILE

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

  # Load list of backups, sorted newest first
  mapfile -t backup_files < <(ls -1t "$BACKUP_DIR"/$backup_pattern 2>/dev/null)

  if [[ ${#backup_files[@]} -eq 0 ]]; then
    echo -e "${RED}❌ No $file_type backups found in $BACKUP_DIR.${NC}"
    return
  fi

  while true; do
    echo
    echo -e "❓ Select a backup to restore, or press ENTER to cancel:"

    # Display menu
    i=1
    for file in "${backup_files[@]}"; do
      echo "  $i) $file"
      ((i++))
    done

    # Read choice
    read -p "Selection: " choice

    # If ENTER pressed → cancel
    if [[ -z "$choice" ]]; then
      echo -e "${YELLOW}⚠️ Restore cancelled by user (no selection).${NC}"
      return
    fi

    # Validate numeric choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backup_files[@]} )); then
      echo -e "${RED}❌ Invalid selection. Try again.${NC}"
      continue
    fi

    # Valid file selected
    selected_file="${backup_files[$((choice-1))]}"
    echo -e "${YELLOW}⚠️ You selected: $selected_file${NC}"
    read -p $"❓ Are you sure you want to proceed with the restore? (y/n): " confirm_restore

    if [[ "${confirm_restore,,}" != "y" ]]; then
      echo -e "${YELLOW}⚠️ Restore aborted by user.${NC}"
      return
    fi

    echo -e "${YELLOW}⚠️ Restoring $file_type from: $selected_file${NC}"

    if [[ "$file_type" == ".env" || "$file_type" == "compose.yaml" ]]; then
      cp "$selected_file" "$target_path"
      echo -e "${GREEN}🚀 Restarting containers...${NC}"
      docker compose -f "$COMPOSE_FILE" up -d
      echo -e "${GREEN}✅ Revert completed.${NC}"
      return
    fi

    if [[ "$file_type" == "MongoDB" ]]; then
      docker cp "$selected_file" mongo:/tmp/restore.gz
      restore_output=$(docker exec mongo sh -c "mongorestore --gzip --archive=/tmp/restore.gz --drop --username $MONGO_INITDB_ROOT_USERNAME --password $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin" 2>&1)
      echo "$restore_output"

      if echo "$restore_output" | grep -qE '[0-9]+ document\(s\) restored successfully\. 0 document\(s\) failed to restore\.'; then
        echo -e "${GREEN}✅ MongoDB restored from backup.${NC}"
      else
        echo -e "${RED}❌ MongoDB restore failed or partial restore.${NC}"
      fi

      docker exec mongo rm -f /tmp/restore.gz
      return
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
    revert_file "MongoDB" "mongo_*_remote-falcon_backup_*.gz"
    ;;
  *)
    echo -e "${RED}❌ Invalid option. Exiting.${NC}"
    exit 1
    ;;
esac