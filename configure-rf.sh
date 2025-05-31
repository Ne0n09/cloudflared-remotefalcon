#!/bin/bash

# VERSION=2025.5.31.1

#set -euo pipefail

CONFIGURE_RF_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/configure-rf.sh"

# Set the URLs to download the compose.yaml, NGINX default.conf, and default .env files
SHARED_FUNCTIONS_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/shared_functions.sh"
DOCKER_COMPOSE_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/remotefalcon/compose.yaml"
NGINX_DEFAULT_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/remotefalcon/default.conf"
DEFAULT_ENV_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/remotefalcon/.env"
UPDATE_RF_CONTAINERS_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/update_rf_containers.sh"
UPDATE_CONTAINERS_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/update_containers.sh"
HEALTH_CHECK_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/health_check.sh"
MINIO_INIT_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/minio_init.sh"
SERVICES=(external-api ui plugins-api viewer control-panel cloudflared nginx mongo minio)
ANY_SERVICE_RUNNING=false

# Function to download file if it does not exist
download_file() {
  local url=$1
  local filename=$2

  if [ ! -f "$filename" ]; then
    echo -e "${YELLOW}⚠️ $filename does not exist. Downloading $filename...${NC}"
    if curl -O "$url"; then
      echo -e "${GREEN}✔ Downloaded $filename successfully.${NC}"
    else
      echo -e "${RED}❌ Failed to download $filename from $url.${NC}"
      exit 1
    fi
  fi
}

echo -e "${BLUE}⚙️ Running ${RED}RF${NC} configuration script...${NC}"

# Download and source shared functions
download_file $SHARED_FUNCTIONS_URL "shared_functions.sh"
chmod +x "shared_functions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/shared_functions.sh" ]]; then
  echo -e "${RED}❌ ERROR: shared_functions.sh does not exist in $SCRIPT_DIR.${NC}"
  exit 1
fi
source "$SCRIPT_DIR/shared_functions.sh"

# Download extra helper scripts if they do not exist and make them executable
download_file $UPDATE_RF_CONTAINERS_URL "update_rf_containers.sh"
download_file $UPDATE_CONTAINERS_URL "update_containers.sh"
download_file $HEALTH_CHECK_URL "health_check.sh"
download_file $MINIO_INIT_URL "minio_init.sh"
chmod +x "shared_functions.sh" "update_rf_containers.sh" "update_containers.sh" "health_check.sh" "minio_init.sh"


# Function to get user input for configuration questions
get_input() {
  local prompt="$1"
  local default="$2"
  local input

  read -p "$prompt [$default]: " input
  echo "${input:-$default}"
}

# Function to update the the .env file with required variables to run RF and some optional variables
update_env() {
  # Declare new variables in an associative array
  declare -A new_env_vars=(
    ["TUNNEL_TOKEN"]="$tunneltoken"
    ["DOMAIN"]="$domain"
#    ["VIEWER_JWT_KEY"]="$viewerjwtkey"
#    ["USER_JWT_KEY"]="$userjwtkey"
#    ["HOSTNAME_PARTS"]="$hostnameparts"
    ["AUTO_VALIDATE_EMAIL"]="$autovalidateemail"
#    ["NGINX_CONF"]="$NGINX_CONF"
    ["NGINX_CERT"]="./${domain}_origin_cert.pem"
    ["NGINX_KEY"]="./${domain}_origin_key.pem"
#    ["HOST_ENV"]="$HOST_ENV"
#    ["VERSION"]="$VERSION"
    ["GOOGLE_MAPS_KEY"]="$GOOGLE_MAPS_KEY"
    ["PUBLIC_POSTHOG_KEY"]="$publicposthogkey"
#    ["PUBLIC_POSTHOG_HOST"]="$PUBLIC_POSTHOG_HOST"
    ["GA_TRACKING_ID"]="$gatrackingid"
    ["MIXPANEL_KEY"]="$mixpanelkey"
#    ["CLIENT_HEADER"]="$CLIENT_HEADER"
#    ["SENDGRID_KEY"]="$SENDGRID_KEY"
#    ["GITHUB_PAT"]="$GITHUB_PAT"
    ["SOCIAL_META"]="$socialmeta"
    ["SEQUENCE_LIMIT"]="$sequencelimit"
  )

  # Detect if any values would change
  pending_changes=false
  for key in "${!new_env_vars[@]}"; do
    current_val=$(grep -E "^${key}=" .env | cut -d'=' -f2-)
    if [[ "${new_env_vars[$key]}" != "$current_val" ]]; then
      pending_changes=true
      break
    fi
  done

  if [ "$pending_changes" = false ]; then
    echo -e "${YELLOW}⚠️ No changes detected — skipping .env update prompt.${NC}"
    return 1
  else
    # Print all answers before asking to update the .env file
    echo
    echo -e "${YELLOW}⚠️ Please confirm the values below are correct:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    # Iterate over the original order of keys
    for key in "${original_keys[@]}"; do
      if [[ -v new_env_vars[$key] ]]; then  # Ensures empty values are displayed
        echo -e "${RED}🔸 $key${NC}=${YELLOW}${new_env_vars[$key]}${NC}"
      fi
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  fi

  # Write the variables to the .env file if answer is y
  if [[ "$(get_input "❓ Update the .env file with the above values? (y/n)" "n" )" =~ ^[Yy]$ ]]; then
    # Refresh the JWT keys when the prompt above is accepted
    new_env_vars["VIEWER_JWT_KEY"]="$(openssl rand -base64 32)"
    new_env_vars["USER_JWT_KEY"]="$(openssl rand -base64 32)"

    # Backup the existing .env file in case roll-back is needed
    timestamp=$(date +'%Y-%m-%d_%H-%M-%S')
    if [[ ! -d "$BACKUP_DIR" ]]; then
      cp .env "$WORKING_DIR/.env.backup-$timestamp"
      echo -e "${YELLOW}⚠️ $BACKUP_DIR does not exist, backed up current .env to $WORKING_DIR/.env.backup-$timestamp${NC}"
    else
      cp .env "$BACKUP_DIR/.env.backup-$timestamp"
      echo -e "${GREEN}✔ Backed up current .env to $BACKUP_DIR/.env.backup-$timestamp${NC}"
    fi

    # Update the .env file
    for key in "${!new_env_vars[@]}"; do
      if grep -q "^${key}=" .env; then
        # Use sed to update the existing key, correctly handling empty values
        sed -i "s|^${key}=.*|${key}=${new_env_vars[$key]}|" .env
      else
        # Append only if it doesn’t exist in the .env file
        echo "${key}=${new_env_vars[$key]}" >> .env
      fi
    done

    # Remove any duplicate lines in the .env file
    awk '!seen[$0]++' .env > .env.tmp && mv .env.tmp .env

    echo -e "${GREEN}✔ Writing variables to .env file completed!${NC}"
    echo
    echo "Printing current .env variables:"
    parse_env
    print_env
    return 0 # Return Success
  else
    echo -e "${YELLOW}⚠️ Variables were not updated! No changes were made to the .env file.${NC}"
    return 1 # Return Failure
  fi
}

# Check for updates to the containers
run_updates() {
  local update_mode="${1:-}"

  if [[ -z "$update_mode" ]]; then
    update_mode="interactive"  # Default to interactive mode if not provided
  fi

  if [[ -z "$TUNNEL_TOKEN" || "$TUNNEL_TOKEN" == "cloudflare_token" ]]; then
    echo -e "${RED}❌ Cloudflared token is missing or still set to a placeholder. Re-run configure-rf.sh to configure.${NC}"
    exit 1
  fi
  if [[ "$DOMAIN" == "your_domain.com" || -z "$DOMAIN" ]]; then
    echo -e "${RED}❌ 'your_domain.com' is a placeholder. Please enter a valid domain.${NC}"
    exit 1
  elif [[ ! "$DOMAIN" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    echo -e "${RED}❌ '$DOMAIN' is not a valid domain format.${NC}"
    exit 1
  fi

  echo -e "${YELLOW}⚠️ Checking for container updates...${NC}"
  case "$update_mode" in
    auto-apply)
      bash "$SCRIPT_DIR/update_containers.sh" "mongo" "auto-apply" # Start with Mongo first since the RF containers depend on it.
      bash "$SCRIPT_DIR/update_rf_containers.sh" "auto-apply"
      bash "$SCRIPT_DIR/update_containers.sh" "minio" "auto-apply"
      bash "$SCRIPT_DIR/update_containers.sh" "nginx" "auto-apply" # Start nginx 2nd to last or it will throw errors if other containers are not up yet.
      bash "$SCRIPT_DIR/update_containers.sh" "cloudflared" "auto-apply" # Start cloudflared last or it will throw errors if nginx isn't running
      ;;
    *)
      # Interactive mode, default
      bash "$SCRIPT_DIR/update_containers.sh" "mongo" # Start with Mongo first since the RF containers depend on it.
      bash "$SCRIPT_DIR/update_rf_containers.sh"
      bash "$SCRIPT_DIR/update_containers.sh" "minio"
      bash "$SCRIPT_DIR/update_containers.sh" "nginx" # Start nginx 2nd to last or it will throw errors if other containers are not up yet.
      bash "$SCRIPT_DIR/update_containers.sh" "cloudflared" # Start cloudflared last or it will throw errors if nginx isn't running
      ;;
  esac

  # Check if the minio_init.sh script exists and run it if it any of the MinIO credentials are set to default values
  if [[ $MINIO_ROOT_USER == "12345678" || $MINIO_ROOT_PASSWORD == "12345678" || $S3_ACCESS_KEY == "123456" || $S3_SECRET_KEY == "123456" ]]; then
    echo -e "${YELLOW}⚠️ MinIO variables are set to the default values. Running minio_init.sh to configure MiniO...${NC}"
    if [ -f "$SCRIPT_DIR/minio_init.sh" ]; then
      bash "$SCRIPT_DIR/minio_init.sh"
    else
      echo -e "${YELLOW}⚠️ minio_init.sh script not found. Skipping MinIO initialization.${NC}"
    fi
  fi
  health_check health
}

# Check if user is root or in the sudo group
if [[ $EUID -eq 0 ]]; then
  # User is root, do nothing
  :
elif id -nG "$USER" | grep -qw "sudo"; then
  # User is in the sudo group, do nothing
  :
else
  echo -e "${YELLOW}⚠️ User '$USER' is NOT root and NOT part of the sudo group.${NC}"
  echo "You must add the user '$USER' to the sudo group or run the script as root."
  echo
  echo "To add a user to the sudo group, usually you can run the following commmands..."
  echo "Switch to the root user: su root"
  echo "Add the user to the sudo group: /sbin/usermod -aG sudo $USER"
  echo "Switch back to the user: su $USER"
  exit 1
fi

# Check if Docker is installed and ask to download and install it if not (For Ubuntu and Debian).
if [ ! -x "$(command -v docker)" ]; then
  if [[ "$(get_input "Docker is not installed, would you like to install it? (y/n)" "y")" =~ ^[Yy]$ ]]; then
    echo "Installing docker... you may need to enter your password for the 'sudo' command."
    # Get OS distribution
    source /etc/os-release
    case $ID in
      ubuntu)
        echo "Installing Docker for Ubuntu..."
        sudo apt-get update && sudo apt-get install ca-certificates curl && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        if [ ! -x "$(command -v docker)" ]; then
          echo -e "${RED}❌ Docker install failed. Please install Docker to proceed.${NC}"
          exit 1
        else
          echo -e "${GREEN}✅ Docker installation for Ubuntu complete!${NC}"
        fi
      ;;
      debian)
        echo "Installing Docker for Debian.."
        sudo apt-get update && sudo apt-get install ca-certificates curl && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        if [ ! -x "$(command -v docker)" ]; then
          echo -e "${RED}❌ Docker install failed. Please install Docker to proceed.${NC}"
          exit 1
        else
          echo -e "${GREEN}✅ Docker installation for Debian complete!${NC}"
        fi
      ;;
      *) echo -e "${RED}❌ Distribution is not supported by this script! Please install Docker manually.${NC}"
      ;;
    esac
  else
    echo -e "${RED}❌ Docker must be installed. Please re-run the script to install Docker and to proceed.${NC}"
    exit 1
  fi
  echo
fi

# Ensure the 'remotefalcon' directory exists
if [ ! -d "$WORKING_DIR" ]; then
  echo -e "${YELLOW}⚠️ Directory '$RF_DIR' does not exist. Creating it in $SCRIPT_DIR...${NC}"
  mkdir "$WORKING_DIR"
fi

# Ensure the 'backup' directory exists
if [ ! -d "$BACKUP_DIR" ]; then
  echo -e "${YELLOW}⚠️ Directory '$BACKUP_DIR' does not exist. Creating it in $SCRIPT_DIR...${NC}"
  mkdir "$BACKUP_DIR"
fi

# Change to the 'remotefalcon' directory and download compose.yaml and default.conf if they do not exist
cd "$WORKING_DIR" || { echo -e "${RED}❌ Failed to change directory to '$WORKING_DIR'. Exiting.${NC}"; exit 1; }
echo "Working in directory: $(pwd)"
download_file $DOCKER_COMPOSE_URL "compose.yaml"
download_file $NGINX_DEFAULT_URL "default.conf"

# Print existing .env file, if it exists, otherwise download the default .env file
if [ -f .env ]; then
  echo "Found existing .env at $ENV_FILE."
  echo "🔍 Parsing current .env variables:"
else
  download_file $DEFAULT_ENV_URL ".env"
  echo "🔍 Parsing default .env variables:"
fi
# Read the .env file and export the variables and print them
parse_env
print_env

# Ask to configure .env values ## Update to proceed if certain values are set to defaults that require updated values
if [[ "$(get_input "❓ Change the .env file variables? (y/n)" "n" )" =~ ^[Yy]$ ]]; then
  # Configuration walkthrough questions. Questions will pull existing or default values from the sourced .env file
  echo
  echo -e "${YELLOW}⚠️ Answer the following questions to update your compose .env variables.${NC}"
  echo "Press ENTER to accept the existing values that are between the brackets [ ]."
  echo "You will be asked to confirm the changes before the file is modified."
  echo
  # ====== REQUIRED variables ======

  # get the Cloudflared tunnel token and validate input is not default, empty, or not in valid format
  while true; do
    tunneltoken=$(get_input "🔐 Enter your Cloudflare sunnel token:" "$TUNNEL_TOKEN")
    if [[ -z "$tunneltoken" || "$tunneltoken" == "cloudflare_token" ]]; then
      echo -e "${RED}❌ Token is missing or still set to a placeholder.${NC}"
    else
      break
    fi
  done

  # Get domain name and validate input is not default, empty, or not in valid domain format
  while true; do
    domain=$(get_input "🌐 Enter your domain name (e.g., yourdomain.com):" "$DOMAIN")
    if [[ "$domain" == "your_domain.com" || -z "$domain" ]]; then
      echo -e "${RED}❌ 'your_domain.com' is a placeholder. Please enter a valid domain.${NC}"
    elif [[ ! "$domain" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      echo -e "${RED}❌ '$domain' is not a valid domain format.${NC}"
    else
      break
    fi
  done

  # Validate auto validate email input, only accept true or false
  while true; do
    autovalidateemail=$(get_input "📧 Enable auto validate email? While set to 'true' anyone can create a viewer page account on your site (true/false):" "$AUTO_VALIDATE_EMAIL")
    autovalidateemail="${autovalidateemail,,}"  # lowercase
    if [[ "$autovalidateemail" == "true" || "$autovalidateemail" == "false" ]]; then
      break
    else
      echo -e "${RED}❌ Please enter 'true' or 'false' only.${NC}"
    fi
  done

  # Removed this hostnameparts question to avoid issues - .env can be manually edited if you have ACM and want a 3 part domain.
  #echo "Enter the number of parts in your hostname. For example, domain.com would be two parts ('domain' and 'com'), and sub.domain.com would be 3 parts ('sub', 'domain', and 'com')"
  #hostnameparts=$(get_input "Cloudflare free only supports two parts for wildcard domains without Advanced Certicate Manager(\$10/month):" "$HOSTNAME_PARTS" )
  #echo
  hostnameparts="$HOSTNAME_PARTS"
  if [[ $hostnameparts == 3 ]]; then
    echo -e "${YELLOW}⚠️ You are using a 3 part domain. Please ensure you have Advanced Certificate Manager enabled in Cloudflare.${NC}"
  fi

  # Ask if Cloudflare origin certificates should be updated if they exist. Otherwise prompt if cert/key files are missing
  # This will create the cert/key in the current directory and append the domain name to the beginning of the file name
  if [[ -f "${domain}_origin_cert.pem" && -f "${domain}_origin_key.pem" ]]; then
    if [[ "$(get_input "❓ Update existing origin certificate and key? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      read -p "Press ENTER to open nano to paste the origin certificate. Ctrl+X, y, and ENTER to save."
      nano "${domain}_origin_cert.pem"
      read -p "Press ENTER to open nano to paste the origin private key. Ctrl+X, y, and ENTER to save."
      nano "${domain}_origin_key.pem"
    fi
  else
    # If origin cert missing
    if [[ ! -f "${domain}_origin_cert.pem" ]]; then
      echo -e "${YELLOW}⚠️ Origin certificate ${domain}_origin_cert.pem not found. Please paste it now.${NC}"
      read -p "Press ENTER to open nano to paste the origin certificate. Ctrl+X, y, and ENTER to save."
      nano "${domain}_origin_cert.pem"
    fi

    # If origin key missing
    if [[ ! -f "${domain}_origin_key.pem" ]]; then
      echo -e "${YELLOW}⚠️ Origin private key ${domain}_origin_key.pem not found. Please paste it now.${NC}"
      read -p "Press ENTER to open nano to paste the origin private key. Ctrl+X, y, and ENTER to save."
      nano "${domain}_origin_key.pem"
    fi
  fi

  # Check VIEWER_JWT_KEY .env variable and generate a random Base64 value if set to default 123456
  if [[ $VIEWER_JWT_KEY == "123456" ]]; then
    #echo -e "${YELLOW}⚠️ VIEWER_JWT_KEY is set to default value 123456. Generating a random key and writing it to $ENV_FILE...${NC}"
    VIEWER_JWT_KEY=$(openssl rand -base64 32)
    sed -i "s|^VIEWER_JWT_KEY=.*|VIEWER_JWT_KEY=$VIEWER_JWT_KEY|" "$ENV_FILE"
  fi

  # Check USER_JWT_KEY .env variable and generate a random Base64 value  if set to default 123456
  if [[ $USER_JWT_KEY == "123456" ]]; then
    #echo -e "${YELLOW}⚠️ USER_JWT_KEY is set to default value 123456. Generating a random key and writing it to $ENV_FILE...${NC}"
    USER_JWT_KEY=$(openssl rand -base64 32)
    sed -i "s|^USER_JWT_KEY=.*|USER_JWT_KEY=$USER_JWT_KEY|" "$ENV_FILE"
  fi

    # ====== OPTIONAL variables ======
  if [[ "$(get_input "❓ Update optional variables (y/n)" "n")" =~ ^[Yy]$ ]]; then
    read -p "🗺️ Enter your Google maps key: [$GOOGLE_MAPS_KEY]: " googlemapskey

    # Ask if analytics env variables should be set for PostHog, Google Analytics, or Mixpanel
    if [[ "$(get_input "❓ Update analytics variables? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      read -p "📊 Enter your PostHog key - https://posthog.com/: [$PUBLIC_POSTHOG_KEY]: " publicposthogkey
      read -p "📊 Enter your Google Analytics Measurement ID - https://analytics.google.com/: [$GA_TRACKING_ID]: " gatrackingid
      read -p "📊 Enter your Mixpanel key - https://mixpanel.com/: [$MIXPANEL_KEY]: " mixpanelkey

      publicposthogkey=${publicposthogkey:-$PUBLIC_POSTHOG_KEY}
      gatrackingid=${gatrackingid:-$GA_TRACKING_ID}
      mixpanelkey=${mixpanelkey:-$MIXPANEL_KEY}
    fi

    # Ask if SOCIAL_META variable should be updated
    if [[ "$(get_input "❓ Update social meta tag? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      echo "See the RF docs for details on the SOCIAL_META tag:"
      echo -e "${BLUE}🔗 https://docs.remotefalcon.com/docs/developer-docs/running-it/digitalocean-droplet?#update-docker-composeyaml${NC}"
      echo
      echo "🏷️ Update SOCIAL_META tag or leave as default - Enter on one line only"
      echo
      read -p "[$SOCIAL_META]: " socialmeta
      socialmeta=${socialmeta:-$SOCIAL_META}
    fi

    # Ask if SEQUENCE_LIMIT variable should be updated
    while true; do
      sequencelimit=$(get_input "🎶 Enter desired sequence limit:" "$SEQUENCE_LIMIT")
        if [[ "$sequencelimit" =~ ^[1-9][0-9]*$ ]]; then
        break
      else
        echo -e "${RED}❌ Please enter a valid whole number greater than 0.${NC}"
      fi
    done
  else
    # Ensure optional variables are set to the current values if they weren't updated
    googlemapskey=${googlemapskey:-$GOOGLE_MAPS_KEY}
    publicposthogkey=${publicposthogkey:-$PUBLIC_POSTHOG_KEY}
    gatrackingid=${gatrackingid:-$GA_TRACKING_ID}
    mixpanelkey=${mixpanelkey:-$MIXPANEL_KEY}
    socialmeta=${socialmeta:-$SOCIAL_META}
    sequencelimit=${sequencelimit:-$SEQUENCE_LIMIT}
  fi
  # Moved service running check down belo

  # Run the container update scripts if .env variables were 'accepted' and 'updated'. This doesn't mean they were changed, just accepted and written to the .env file.
  if update_env; then
    # Check if containers are running and then do 'docker compose up -d --force-recreate' to ensure .env changes are applied
    for service in "${SERVICES[@]}"; do
      if sudo docker compose -f "$COMPOSE_FILE" ps --services --filter "status=running" | grep -q "^$service$"; then
        ANY_SERVICE_RUNNING=true
      fi
    done
    if [[ $ANY_SERVICE_RUNING == true ]]; then
      echo -e "${YELLOW}⚠️ Containers are running. Running 'docker compose up -d --force-recreate' to apply .env changes...${NC}"
      sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate 
      # Prompt to check updates after applying new .env values to existing containers
      if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        run_updates
      elif [[ "$(get_input "❓ Run health check script? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        health_check health
      fi
    else # Automatically run container updates and update image tags in the compose.yaml file
        run_updates auto-apply
    fi
  else # update_env returned false - Ask to run update check anyway
    if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      run_updates
    elif [[ "$(get_input "❓ Run health check script? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        health_check health
    fi
  fi
else # User chose not to update the .env file
  echo -e "${YELLOW}⚠️ No .env variables modified.${NC}"
  if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
    run_updates
  elif [[ "$(get_input "❓ Run health check script? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      health_check health
  fi
fi

echo -e "${GREEN}🎉 Done! Exiting ${RED}RF${NC} configuration script...${NC}"
exit 0
