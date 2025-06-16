#!/bin/bash

# VERSION=2025.6.6.1

#set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared_functions.sh"

# Function to toggle showRole
toggle_show_role() {
  local selected_show=$1
  local results=$(sudo docker exec mongo bash -c "
    mongosh --quiet 'mongodb://root:root@localhost:27017' --eval '
      db = db.getSiblingDB(\"remote-falcon\");
      const selectedShow = \"$selected_show\";
      const show = db.show.findOne({ showSubdomain: selectedShow });
      if (show) {
        const newRole = show.showRole === \"ADMIN\" ? \"USER\" : \"ADMIN\";
        db.show.updateOne(
          { showSubdomain: selectedShow },
          { \$set: { showRole: newRole } }
        );
        print(\"Updated showRole for \" + selectedShow + \" to \" + newRole);
      } else {
        print(\"Error: Show not found: \" + selectedShow);
      }
    '
  ")

  echo "$results" | while read -r line; do
    if [[ "$line" == "Updated showRole for"* ]]; then
      echo -e "${GREEN}✅ $line${NC}"
    elif [[ "$line" == "Error: Show not found:"* ]]; then
      echo -e "${RED}❌ $line${NC}"
    else
      echo "$line"
    fi
  done
}

container_name="mongo"

# Check if the container is running
if sudo docker ps --filter "name=$container_name" --filter "status=running" --format "{{.Names}}" | grep -q "^$container_name$"; then

  echo -e "${GREEN}✅ $container_name is running.${NC}"
  echo -e "${CYAN}🔍 Retrieving list of showSubdomains and current showRoles from MongoDB...${NC}"

  SHOWS=$(sudo docker exec mongo bash -c "
    mongosh --quiet 'mongodb://root:root@localhost:27017' --eval '
      db = db.getSiblingDB(\"remote-falcon\");
      const shows = db.show.find({}, { showSubdomain: 1, showRole: 1 }).sort({ showSubdomain: 1 }).toArray();
      shows.forEach(show => print(show.showSubdomain + \" | \" + show.showRole));
    '
  ")

  if [ -z "$SHOWS" ]; then
    echo -e "${YELLOW}⚠️ No shows found.${NC}"
    exit 1
  fi

  # Parse the list into an array
  IFS=$'\n' read -rd '' -a SHOW_ARRAY <<<"$SHOWS"

  # Print header
  printf "\n%-4s %-30s %s\n" "No." "Show Subdomain" "Role"
  printf "%-4s %-30s %s\n" "----" "------------------------------" "----"

  # Print numbered list
  index=1
  for show in "${SHOW_ARRAY[@]}"; do
    IFS='|' read -r subdomain role <<<"$show"
    subdomain=$(echo "$subdomain" | xargs)
    role=$(echo "$role" | xargs)

    if [[ "$role" == "ADMIN" ]]; then
        dot="🔹"
        color="${BLUE}"
    elif [[ "$role" == "USER" ]]; then
        dot="🔸"
        color="${YELLOW}"
    else
        dot="•"
        color="${NC}"
    fi

    printf "%-4s %-30s " "$index" "$subdomain"
    printf "%b\n" "${color}${dot} $role${NC}"

    SHOW_MAP[$index]="$subdomain"
    ((index++))
  done

  # Prompt user to select a show by number
  echo ""
  read -p "❓ Enter the number of the show to toggle its role, or press ENTER to exit: " selected_number
  if [[ -z "$selected_number" ]]; then
    echo "Exiting without changes."
    exit 0
  elif [[ -n "${SHOW_MAP[$selected_number]}" ]]; then
    selected_subdomain="${SHOW_MAP[$selected_number]}"
    echo -e "${CYAN}🔄 Toggling role for '$selected_subdomain'...${NC}"
    toggle_show_role "$selected_subdomain"
  else
    echo -e "${RED}❌ Invalid selection.${NC}"
    exit 1
  fi

else
  echo -e "${RED}❌ The container '$container_name' is not running.${NC}"
  exit 1
fi