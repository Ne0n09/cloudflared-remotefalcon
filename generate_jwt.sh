#!/bin/bash

# VERSION=2025.6.6.1

#set -euo pipefail

# Generate a JWT using bash for use with the RF external-api

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared_functions.sh"

# Name of the container to check
container_name="mongo"

# Check if the container exists
if sudo docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
  echo -e "${GREEN}✅ $container_name is running.${NC}"
  echo -e "${CYAN}🔍 Finding API details from MongoDB for shows that requested API access...${NC}"
  echo

  # Run Mongo query to get showSubdomain, token, and secret as a flat list
  SHOWS_RAW=$(sudo docker exec mongo bash -c "
    mongosh --quiet 'mongodb://root:root@localhost:27017' --eval '
      db = db.getSiblingDB(\"remote-falcon\");
      const shows = db.show.aggregate([
          { \$match: { \"apiAccess.apiAccessActive\": true } },
          { \$project: { _id: 0, showSubdomain: \"\$showSubdomain\", apiAccessToken: \"\$apiAccess.apiAccessToken\", apiAccessSecret: \"\$apiAccess.apiAccessSecret\" } }
      ]).toArray();
      shows.forEach(show => print(show.showSubdomain + \"|\" + show.apiAccessToken + \"|\" + show.apiAccessSecret));
    '
  ")

  # Check if anything was returned
  if [ -z "$SHOWS_RAW" ]; then
    echo -e "${YELLOW}⚠️ No shows found with API access.${NC}"
    exit 1
  fi

  # Convert SHOWS_RAW into an array
  IFS=$'\n' read -rd '' -a SHOW_ARRAY <<<"$SHOWS_RAW"

  # Display numbered list of shows
  echo "No.  Show Subdomain"
  echo "---- ------------------------------"

  declare -A SHOW_MAP
  index=1
  for show in "${SHOW_ARRAY[@]}"; do
    IFS='|' read -r subdomain token secret <<<"$show"
    subdomain=$(echo "$subdomain" | xargs)
    printf "%-4s %-30s\n" "$index" "$subdomain"
    SHOW_MAP[$index]="$show"
    ((index++))
  done

  echo

  # Prompt user to select show
  read -p "❓ Enter the number of the show to generate a JWT, or press ENTER to exit: " selected_number

  if [ -z "$selected_number" ]; then
    echo "Exiting without changes."
    exit 0
  elif [[ -n "${SHOW_MAP[$selected_number]}" ]]; then
    # Extract token/secret from selected show
    IFS='|' read -r selected_subdomain accessToken secretKey <<<"${SHOW_MAP[$selected_number]}"

    echo
    echo -e "${CYAN}🔄 Using apiAccessToken and apiAccessSecret to generate JWT for '$selected_subdomain'...${NC}"

    # Create Header (JSON)
    header='{"typ":"JWT","alg":"HS256"}'

    # Create Payload (JSON)
    payload="{\"accessToken\":\"$accessToken\"}"

    # Base64Url encode a string
    base64url_encode() {
      echo -n "$1" | openssl base64 -e | tr -d '\n=' | tr '+/' '-_'
    }

    # Encode Header and Payload to Base64Url
    base64UrlHeader=$(base64url_encode "$header")
    base64UrlPayload=$(base64url_encode "$payload")

    # Create Signature (HMAC with SHA256)
    signature=$(echo -n "$base64UrlHeader.$base64UrlPayload" | openssl dgst -sha256 -hmac "$secretKey" -binary | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

    # Create JWT
    jwt="$base64UrlHeader.$base64UrlPayload.$signature"

    # Output JWT
    echo -e "${GREEN}✅ Your JWT is:${NC} "
    echo -e "${YELLOW}$jwt${NC}"
  else
    echo -e "${RED}❌ Invalid selection.${NC}"
    exit 1
  fi
else
  echo -e "${RED}❌ The container '$container_name' is not running.${NC}"
  exit 1
fi
