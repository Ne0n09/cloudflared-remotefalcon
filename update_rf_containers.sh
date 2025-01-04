#!/bin/bash

# This script will get the latest commit short hash and details from the RF GitHub repos.
# It will then update the compose.yaml image tag with the short hash, build the image, and start the container with the image tagged to the hash.
# This makes it easier to see how 'up to date' your RF containers are versus just having them set to 'latest'
# Example sudo docker ps output:
# CONTAINER ID   IMAGE                              COMMAND                  CREATED        STATUS        PORTS                                                 NAMES
# 6a5b9d3ab5ba   control-panel:3557af5              "/bin/sh -c 'exec ja…"   14 hours ago   Up 14 hours   8080/tcp                                              control-panel
# 24813711c096   viewer:07edd6a                     "/bin/sh -c 'exec ja…"   14 hours ago   Up 14 hours   8080/tcp                                              viewer
# 54a952d9c1e9   mongo:latest                       "docker-entrypoint.s…"   15 hours ago   Up 15 hours   27017/tcp                                             mongo
# 16ee2bc20b2e   cloudflare/cloudflared:2024.12.1   "cloudflared --no-au…"   15 hours ago   Up 15 hours                                                         cloudflared
# 790cd1e80d86   plugins-api:fe7c932                "/bin/sh -c 'exec ja…"   16 hours ago   Up 16 hours   8080/tcp, 0.0.0.0:8083->8083/tcp, :::8083->8083/tcp   plugins-api
# 18e6c6d8e79c   external-api:a9f4918               "/bin/sh -c 'exec ja…"   16 hours ago   Up 16 hours   8080/tcp                                              external-api
# 6e052fb1fe39   nginx:latest                       "/docker-entrypoint.…"   16 hours ago   Up 16 hours   80/tcp                                                nginx

# This script can be run directly by itself to only update the RF containers:
# Skipping the health_check.sh script: ./update_rf_containers.sh" --no-health
# OR with the health_check.sh script: ./update_rf_containers.sh"
# The script will display the changes found and ask if you would like to update the container(s)
# By default it will run a health check when unless --no-health is specified: update_rf_containers.sh --no-health

# Set the script version in YYYY.MM.DD.X to allow for update checking and downloading
VERSION=2025.1.2.1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RF_DIR="remotefalcon"
WORKING_DIR="$SCRIPT_DIR/$RF_DIR"
COMPOSE_FILE="$WORKING_DIR/compose.yaml"
HEALTH_CHECK_SCRIPT="$SCRIPT_DIR/health_check.sh"
NO_HEALTH=$1

# Check if compose file exists
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Error: $COMPOSE_FILE not found."
  exit 1
fi

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

# Array of RF containers and their GitHub repos in order to check for updates and compare changes
CONTAINERS=(
  "external-api|https://github.com/Remote-Falcon/remote-falcon-external-api.git|main"
  "ui|https://github.com/Remote-Falcon/remote-falcon-ui.git|main"
  "plugins-api|https://github.com/Remote-Falcon/remote-falcon-plugins-api.git|main"
  "viewer|https://github.com/Remote-Falcon/remote-falcon-viewer.git|main"
  "control-panel|https://github.com/Remote-Falcon/remote-falcon-control-panel.git|main"
)

# Function to check if a container running
container_running() {
  local container_name="$1"
  sudo docker ps --filter "name=$container_name" --format '{{.Names}}' | grep -q "$container_name"
}

update_tag_and_build_container() {
  local container_name="$1"
  local short_latest_hash="$2"
  # Update the image tag in the compose.yaml with the latest short hash
  sed -i "s|image:.*$container_name:.*|image: $container_name:$short_latest_hash|g" "$COMPOSE_FILE"

  # Build the new container image with the updated short hash tag
  echo
  echo "Building new '$container_name' image tagged with hash '$short_latest_hash' using 'sudo docker compose build $container_name'"
  sudo docker compose -f "$COMPOSE_FILE" build "$container_name"
}

echo
echo "Running update script for Remote Falcon containers..."

# Loop through each RF container, check its tags in compose.yaml and update the tag as appropriate
declare -A UPDATE_INFO
echo "Checking Remote Falcon container image tags in '$COMPOSE_FILE'..."
for container_info in "${CONTAINERS[@]}"; do
  IFS='|' read -r CONTAINER_NAME REPO_URL BRANCH <<< "$container_info"
  echo "Checking container '$CONTAINER_NAME'..."
  # Get the image tag of the container from the compose.yaml
  CURRENT_COMPOSE_TAG=$(sed -n "/$CONTAINER_NAME:/,/image:/s|.*image:.*:\([^ ]*\)|\1|p" "$COMPOSE_FILE" | xargs | tr -d '\r\n')

  # Fetch the latest commit hash for the branch
  LATEST_HASH=$(git ls-remote "$REPO_URL" "$BRANCH" | awk '{print $1}')
  if [[ -z $LATEST_HASH ]]; then
    echo "Failed to retrieve the latest commit hash for $CONTAINER_NAME."
    continue
  fi
  # Convert the latest commit hash to a short hash
  SHORT_LATEST_HASH=$(echo "$LATEST_HASH" | cut -c 1-7)

  # Check the current compose tag is in the valid short hash format 'abc1234'
  if [[ "$CURRENT_COMPOSE_TAG" =~ ^[a-fA-F0-9]{7}$ ]]; then
    echo "Container '$CONTAINER_NAME' has a valid short hash: $CURRENT_COMPOSE_TAG"
    # Download changes from current short hash image tag to the latest short hash in order to display changes later
    if [[ ! "$CURRENT_COMPOSE_TAG" == "$SHORT_LATEST_HASH" ]]; then
      # Clone the repository to view commit history
      TEMP_DIR=$(mktemp -d)
      git clone --quiet --branch "$BRANCH" "$REPO_URL" "$TEMP_DIR"

      if [[ $? -ne 0 ]]; then
        echo "Failed to clone the repository for '$CONTAINER_NAME'"
        rm -rf "$TEMP_DIR"
        continue
      fi

      cd "$TEMP_DIR"
      COMMIT_HISTORY=$(git log --oneline --pretty=format:"%h %s%n%B" "$CURRENT_COMPOSE_TAG..$LATEST_HASH")
      echo "Container '$CONTAINER_NAME' current version: $CURRENT_COMPOSE_TAG - latest version: $SHORT_LATEST_HASH"
      cd - >/dev/null

      # Store update information
      UPDATE_INFO["$CONTAINER_NAME"]="$SHORT_LATEST_HASH|$COMMIT_HISTORY"

      # Clean up the temporary directory
      rm -rf "$TEMP_DIR"
    else
      echo "Container '$CONTAINER_NAME' is at the latest version: $SHORT_LATEST_HASH"
    fi
  else # Image tag in compose is not a valid short hash - either new or existing setups that do not use the 'abc1234' hash format
    # Check if container is running and ask to update to latest hash tag or if container is not running update to the latest hash tag
    echo "Container '$CONTAINER_NAME' does not have a valid short hash image tag: $CURRENT_COMPOSE_TAG"
    if container_running "$CONTAINER_NAME"; then
      echo "Container '$CONTAINER_NAME' is running."
      read -p "Would you like to update the image tag for '$CONTAINER_NAME' to '$SHORT_LATEST_HASH' and rebuild the container? (y/n): " CONFIRM
      if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        update_tag_and_build_container "$CONTAINER_NAME" "$SHORT_LATEST_HASH"
      else
        echo "Container '$CONTAINER_NAME' image tag not updated. Current image tag remains: $CURRENT_COMPOSE_TAG"
      fi
    else
      # Container is not running and the image tag is not a hash, auto update the compose tag for the container with the latest short hash and start the container
      update_tag_and_build_container "$CONTAINER_NAME" "$SHORT_LATEST_HASH"
    fi
  fi
  echo
done
echo "Done checking Remote Falcon container image tags."
echo

# Display no updates detected if UPDATE_INFO is empty or display all the available updates and prompt to update
if [[ ${#UPDATE_INFO[@]} -eq 0 ]]; then
  echo "Done checking for Remote Falcon container updates."
  echo "No updates detected for any Remote Falcon containers."
else
  # Display all updates and prompt to update the image tag for each container
  echo "Updates detected for the following Remote Falcon containers:"
  for CONTAINER_NAME in "${!UPDATE_INFO[@]}"; do
    SHORT_LATEST_HASH=$(echo "${UPDATE_INFO["$CONTAINER_NAME"]}" | sed -n '1s/^\(.......\).*/\1/p')
    COMMIT_HISTORY=$(echo "${UPDATE_INFO["$CONTAINER_NAME"]}" | cut -d'|' -f2-)
    # Get the image tag of the container from the compose.yaml
    CURRENT_COMPOSE_TAG=$(sed -n "/$CONTAINER_NAME:/,/image:/ s/image:.*:\(.*\)/\1/p" "$COMPOSE_FILE" | xargs)

    echo
    echo "Container '$CONTAINER_NAME' - (Repo: $REPO_URL, Branch: $BRANCH)"
    echo "Commit history:"
    echo "$COMMIT_HISTORY"
    echo
    read -p "Would you like to update the version for container '$CONTAINER_NAME' to '$SHORT_LATEST_HASH'? (y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
      echo "Updating container '$CONTAINER_NAME' to image tag '$SHORT_LATEST_HASH' in $COMPOSE_FILE..."
      update_tag_and_build_container "$CONTAINER_NAME" "$SHORT_LATEST_HASH"
    fi
  done
fi

echo "Bringing up any stopped/missing Remote Falcon containers..."

# Bring all RF containers up with 'sudo docker compose up -d' after checking/updating image tags above
# This ensure all containers are brought up whether they were updated or not
for container_info in "${CONTAINERS[@]}"; do
  IFS='|' read -r CONTAINER_NAME REPO_URL BRANCH <<< "$container_info"
#  echo "Bringing container '$CONTAINER_NAME' up 'sudo docker compose up -d $CONTAINER_NAME..."
  sudo docker compose -f "$COMPOSE_FILE" up -d "$CONTAINER_NAME"
done

echo "Done checking for Remote Falcon container updates."
health_check
echo "Done! Exiting update Remote Falcon containers script..."
exit 0