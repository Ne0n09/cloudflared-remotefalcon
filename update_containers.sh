#!/bin/bash

# Accepts arguments bash "$SCRIPT_DIR/update_container.sh" container-name --no-health
# $1=container_name $2=--no-health
# This script will check for and display updates for cloudflared, nginx, and mongo containers
# ./update_containers.sh cloudflared
# ./update_containers.sh nginx
# ./update_containers.sh mongo

SCRIPT_VERSION=2025.1.4.1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RF_DIR="remotefalcon"
WORKING_DIR="$SCRIPT_DIR/$RF_DIR"
COMPOSE_FILE="$WORKING_DIR/compose.yaml"
ENV_FILE="$WORKING_DIR/.env"
HEALTH_CHECK_SCRIPT="$SCRIPT_DIR/health_check.sh"
BACKUP_DIR=$SCRIPT_DIR 
DB_NAME="remote-falcon"
CONTAINER_NAME=$1
NO_HEALTH=$2

# Check if the compose file exists
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Error: $COMPOSE_FILE not found."
  exit 1
fi

parse_env() {
  # Load the existing .env variables to allow for auto-completion
  declare -gA existing_env_vars
  original_keys=()
  while IFS='=' read -rs line; do
    # Ignore any comment lines and empty lines
    if [[ $line == \#* || -z "$line" ]]; then
      continue
    fi

    # Split the line into key and value
    key="${line%%=*}"
    value="${line#*=}"
    existing_env_vars["$key"]="$value"
    original_keys+=("$key")

    export "$key"="$value" # Export the variable for auto-completion
  done < $ENV_FILE
}

# Health check function to call health check script with override to do --no-health to avoid repeated health checks in the main configure-rf script
health_check() {
  # Check if the --no-health argument is passed
  if [[ "$NO_HEALTH" == "--no-health" ]]; then
    return 0  # Skip the health check and continue the script
  fi

  # Check if the health check script exists and is executable
  if [[ -x "$HEALTH_CHECK_SCRIPT" ]]; then
    "$HEALTH_CHECK_SCRIPT"
  else
    echo "Error: Health check script not found or not executable at $HEALTH_CHECK_SCRIPT"
    exit 0 # Continue running anyway
  fi
}

# Define release notes URL for each container
case "$CONTAINER_NAME" in
  "cloudflared")
    RELEASE_NOTES_URL="https://raw.githubusercontent.com/cloudflare/cloudflared/refs/heads/master/RELEASE_NOTES"
    ;;
  "nginx")
    RELEASE_NOTES_URL="https://nginx.org/en/CHANGES"
    ;;
  "mongo")
    RELEASE_NOTES_URL="https://raw.githubusercontent.com/docker-library/repo-info/refs/heads/master/repos/mongo/tag-details.md"
    ;;
  *)
    echo "Unsupported container: $CONTAINER_NAME" >&2
    echo "Usage:"
    echo "./update_containers.sh cloudflared"
    echo "./update_containers.sh nginx"
    echo "./update_containers.sh mongo"
    exit 1
    ;;
esac

# Function to fetch the latest version(s) for a container from its release notes URL
fetch_latest_version() {
  local container_name=$1
  local release_notes_url=$2

  case "$container_name" in
    "cloudflared")
      curl -s "$release_notes_url" | grep -Eo '^[0-9]{4}\.[0-9]{2}\.[0-9]+' | head -n 1
      ;;
    "nginx")
      curl -s "$release_notes_url" | grep -Eo 'nginx [0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | awk '{print $2}'
      ;;
    "mongo")
      curl -s "$release_notes_url" | grep -oP 'mongo:\K[\d]+\.[\d]+\.[\d]+' | sort -u
      ;;
    *)
      echo "Failed to fetch latest version. Unsupported container: $container_name" >&2
      exit 1
      ;;
  esac
}

# Function to fetch current version directly from the container after it is running
fetch_current_version() {
  local container_name=$1

  case "$container_name" in
    "cloudflared")
      sudo docker exec cloudflared cloudflared --version | sed -n 's/^cloudflared version \([0-9.]*\).*/\1/p'
      ;;
    "nginx")
      sudo docker exec nginx nginx -v 2>&1 | sed -n 's/^nginx version: nginx\///p'
      ;;
    "mongo")
      sudo docker exec -it mongo bash -c "mongod --version | grep -oP 'db version v\\K[\\d\\.]+'" | tr -d '[:space:]'
      ;;
    *)
      echo "Failed to fetch current version. Unsupported container: $container_name" >&2
      exit 1
      ;;
  esac
}

prompt_to_update() {
  local container_name="$1"
  local latest_version="$2"
  local sed_command="$3"

  # Prompt user to update
  read -p "Would you like to update container '$container_name' to the $latest_version version? (y/n): " CONFIRM

  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    # Offer to backup mongo prior ot update
    if $container_name == "mongo"; then
      backup_mongo "mongo"
    fi
    # Update the tag
    sed -i.bak -E $3 "$COMPOSE_FILE"
    echo "Updated container '$container_name' image tag to version $latest_version in $COMPOSE_FILE..."

    # Restart the container with the new image
    echo "Restarting container '$container_name' with the $latest_version image..."
    sudo docker compose -f "$COMPOSE_FILE" pull "$container_name"
    sudo docker compose -f "$COMPOSE_FILE" up -d "$container_name"
    echo "Container '$container_name' update complete!"
    health_check
    exit 0
  else
    echo "Container '$container_name' update cancelled by user."
    exit 1
  fi
}

backup_mongo() {
  # Define container name and backup directory
  local container_name="$1" 

  # Load environment variables from .env file
  if [ -f "$ENV_FILE" ]; then
    parse_env
  else
    echo "Error: $ENV_FILE file not found."
    exit 1
  fi

  # Check if required variables are set
  if [ -z "$MONGO_PATH" ]; then
    echo "Error: MONGO_PATH not set in the .env file."
    exit 1
  fi

  # Prompt the user for confirmation to backup
  read -p "Do you want to create a backup of the container '$container_name' MongoDB database? (y/n): " CONFIRM

  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Backup operation canceled."
  else
    # Generate a backup filename with date
    BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_backup_$(date +'%Y-%m-%d_%H-%M-%S').gz"

    echo "Creating backup of the '$DB_NAME' database from container '$container_name'..."

    sudo docker exec $container_name mongodump --archive=/tmp/backup.archive --gzip --db $DB_NAME --username root --password root --authenticationDatabase admin

    # Copy the backup file from the container to the local machine
    sudo docker cp $container_name:/tmp/backup.archive $BACKUP_FILE

    # Confirm completion and cleanup
    if [ -f "$BACKUP_FILE" ]; then
      echo "Backup completed successfully and stored in: $BACKUP_FILE"
      sudo docker exec $container_name rm /tmp/backup.archive  # Clean up temporary backup file inside the container
    else
      echo "Backup failed. Please check the container logs for more information."
      exit 1
    fi
  fi
}

# Fetch latest version(s) from the release notes
LATEST_VERSION=$(fetch_latest_version "$CONTAINER_NAME" "$RELEASE_NOTES_URL")
if [[ -z "$LATEST_VERSION" ]]; then
  echo "Failed to fetch the latest version for container '$CONTAINER_NAME' from $RELEASE_NOTES_URL."
  exit 1
fi

echo
echo "Running update script for container '$CONTAINER_NAME'"

#echo "Checking if container '$CONTAINER_NAME' is running..."
if sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "Container '$CONTAINER_NAME' is running."
else
  echo "Container '$CONTAINER_NAME' does not exist or is not running."
  echo "Attempting to start '$CONTAINER_NAME'..."
  sudo docker compose -f "$COMPOSE_FILE" up -d "$CONTAINER_NAME"
  echo "Sleeping 10 seconds to let container '$CONTAINER_NAME' start in order to check its version directly..."
  sleep 10s
fi

# Fetch current container version directly from the container
CURRENT_VERSION=$(fetch_current_version "$CONTAINER_NAME")
if [[ -z "$CURRENT_VERSION" ]]; then
  echo "Failed to fetch the current version for container '$CONTAINER_NAME'"
  exit 1
fi
echo "Container '$CONTAINER_NAME' current version: $CURRENT_VERSION"

# Update logic for each container: cloudflared, nginx, mongo
case "$CONTAINER_NAME" in
    "cloudflared")
      # Check if the current version is in the valid XXXX.XX.X format
      if [[ ! $CURRENT_VERSION =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]+$ ]]; then
        echo "Container '$CONTAINER_NAME' current version '$CURRENT_VERSION' is not in the valid format (XXXX.XX.X)."
      fi

      # Display latest version
      echo "Container '$CONTAINER_NAME' latest version: $LATEST_VERSION"

      # Exit early if the current version is the latest patch
      if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "Container '$CONTAINER_NAME' is at the latest version: $LATEST_VERSION"
        exit 0
      fi

      # Fetch all release notes
      RELEASE_NOTES=$(curl -s "$RELEASE_NOTES_URL")

      # Flag to track if we are between the versions
      BETWEEN_VERSIONS=0

      echo -e "\nChanges between version $CURRENT_VERSION and $LATEST_VERSION:"

      # Loop through each line of the release notes
      while IFS= read -r line; do
        # If we encounter the CURRENT_VERSION, we start capturing changes
        if [[ "$line" =~ ^$LATEST_VERSION ]]; then
          BETWEEN_VERSIONS=1
          # echo -e "\nVersion $line:"
        fi
        if [[ "$line" =~ ^$CURRENT_VERSION ]]; then
            break
        fi
        # If we are between versions and the line starts with "-", it's a change
        if [[ "$BETWEEN_VERSIONS" -eq 1 ]]; then
          echo "$line"
        fi
      done <<< "$RELEASE_NOTES"

      prompt_to_update $CONTAINER_NAME $LATEST_VERSION "s|cloudflare/$CONTAINER_NAME:[^[:space:]]+|cloudflare/$CONTAINER_NAME:$LATEST_VERSION|"
      ;;
    "nginx")
      # Check if the current tag is in the valid XX.XX.XX format
      if [[ ! "$CURRENT_VERSION" =~ ^[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
        echo "Container '$CONTAINER_NAME' current version '$CURRENT_VERSION' is not in the valid format (XX.XX.XX)."
      fi

      # Display latest version
      echo "Container '$CONTAINER_NAME' latest version: $LATEST_VERSION"

      # Exit early if the current version is the latest patch
      if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "Container '$CONTAINER_NAME' is at the latest version: $LATEST_VERSION"
        exit 0
      fi

      # Fetch all release notes
      RELEASE_NOTES=$(curl -s "$RELEASE_NOTES_URL")

      # Flag to track if we are between the versions
      BETWEEN_VERSIONS=0

      echo -e "\nChanges between version $CURRENT_VERSION and $LATEST_VERSION:"

      # Loop through each line of the release notes
      while IFS= read -r line; do
        # If we encounter the CURRENT_VERSION, we start capturing changes
        if [[ "$line" =~ Changes\ with\ $CONTAINER_NAME\ $LATEST_VERSION ]]; then
          BETWEEN_VERSIONS=1
        fi
        if [[ "$line" =~ Changes\ with\ $CONTAINER_NAME\ $CURRENT_VERSION ]]; then
            break
        fi
        # If we are between versions display the lines for the changes
        if [[ "$BETWEEN_VERSIONS" -eq 1 ]]; then
          echo "$line"
        fi
      done <<< "$RELEASE_NOTES"

      prompt_to_update $CONTAINER_NAME $LATEST_VERSION "/^\s*image:\s*$CONTAINER_NAME:[^[:space:]]+/s|$CONTAINER_NAME:[^[:space:]]+|$CONTAINER_NAME:$LATEST_VERSION|"
      ;;
    "mongo")
      # Check if the current version is in the valid X.X.XX format
      if [[ ! $CURRENT_VERSION =~ ^[0-9]{1,2}\.[0-9]+\.[0-9]{1,2}$ ]]; then
        echo "Container '$CONTAINER_NAME' current version '$CURRENT_VERSION' is not in the valid format (XX.X.XX)."
      fi

      # Function to extract the major version from a version string
      get_major_version() {
        echo "$1" | cut -d'.' -f1
      }

      # Get the major version of the current MongoDB
      CURRENT_MAJOR=$(get_major_version "$CURRENT_VERSION")

      # Find the latest patch version for the current major version
      LATEST_SAME_MAJOR=$(echo "$LATEST_VERSION" | grep -E "^$CURRENT_MAJOR\." | sort -V | tail -n 1)
      echo "Latest current major patch version: $LATEST_SAME_MAJOR"

      # Find the next major version available
      NEXT_MAJOR=$((CURRENT_MAJOR + 1))
      LATEST_NEXT_MAJOR=$(echo "$LATEST_VERSION" | grep -E "^$NEXT_MAJOR\." | sort -V | tail -n 1)
      if [[ -n "$LATEST_NEXT_MAJOR" ]]; then
        echo "Latest next major patch version: $LATEST_NEXT_MAJOR"
      fi

      # Exit early if the current version is the latest patch
      if [[ "$CURRENT_VERSION" == "$LATEST_SAME_MAJOR" && "$LATEST_NEXT_MAJOR" == "" ]]; then
        echo "Container '$CONTAINER_NAME' is at the latest current major patch version: $LATEST_SAME_MAJOR"
        exit 0
      fi

      # Display recent Mongo versions
      echo "Recent MongoDB versions are listed below:"
      echo "$LATEST_VERSION" | tr ' ' '\n'
      echo "See MongoDB release notes here to confirm upgrade paths: https://www.mongodb.com/docs/manual/release-notes/"

      # Offer update to latest patch version within the current major
      if [[ "$CURRENT_VERSION" != "$LATEST_SAME_MAJOR" ]]; then
        echo "A newer patch version for your current major version ($CURRENT_MAJOR.x.x) is available: $LATEST_SAME_MAJOR"
        prompt_to_update $CONTAINER_NAME $LATEST_SAME_MAJOR "/^\s*image:\s*$CONTAINER_NAME:[^[:space:]]+/s|$CONTAINER_NAME:[^[:space:]]+|$CONTAINER_NAME:$LATEST_SAME_MAJOR|"
      fi

      # Offer update to the next major version
      if [[ -n "$LATEST_NEXT_MAJOR" ]]; then
        echo "A newer major version is available: $LATEST_NEXT_MAJOR."
        prompt_to_update $CONTAINER_NAME $LATEST_NEXT_MAJOR "/^\s*image:\s*$CONTAINER_NAME:[^[:space:]]+/s|$CONTAINER_NAME:[^[:space:]]+|$CONTAINER_NAME:$LATEST_NEXT_MAJOR|"
      fi
      ;;
    *)
      echo "Failed to update container. Unsupported container: $CONTAINER_NAME" >&2
      exit 1
      ;;
  esac

echo "No updates were applied. Container '$CONTAINER_NAME' version remains at $CURRENT_VERSION."