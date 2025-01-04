#!/bin/bash

VERSION=2025.1.4.1
CONFIGURE_RF_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/configure-rf.sh"

# Set the URLs to download the compose.yaml, NGINX default.conf, and default .env files
DOCKER_COMPOSE_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/remotefalcon/compose.yaml"
NGINX_DEFAULT_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/remotefalcon/default.conf"
DEFAULT_ENV_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/remotefalcon/.env"
UPDATE_RF_CONTAINERS_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/update_rf_containers.sh"
UPDATE_CONTAINERS_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/update_containers.sh"
HEALTH_CHECK_URL="https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/health_check.sh"

# Get the directory where the script is located and set the RF directory to 'remotefalcon'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RF_DIR="remotefalcon"
WORKING_DIR="$SCRIPT_DIR/$RF_DIR"

# Function to download file if it does not exist
download_file() {
  local url=$1
  local filename=$2

  if [ ! -f "$filename" ]; then
    echo "$filename does not exist. Downloading $filename..."
    if curl -O "$url"; then
      echo "Downloaded $filename successfully."
    else
      echo "Failed to download $filename from $url."
      exit 1
    fi
  fi
}

# Function to get user input for configuration questions
get_input() {
  local prompt="$1"
  local default="$2"
  local input

  read -p "$prompt [$default]: " input
  echo "${input:-$default}"
}

# Function to read the .env file
parse_env() {
  echo
  echo "--------------------------------"
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
    echo "$key=$value"
  done < .env
  echo "--------------------------------"
}

# Function to update the .env file
update_env() {
  # Declare new variables in an associative array
  declare -A new_env_vars=(
    ["TUNNEL_TOKEN"]="$tunneltoken"
    ["DOMAIN"]="$domain"
    ["VIEWER_JWT_KEY"]="$viewerjwtkey"
    ["HOSTNAME_PARTS"]="$hostnameparts"
    ["AUTO_VALIDATE_EMAIL"]="$autovalidateemail"
    ["NGINX_CONF"]="$NGINX_CONF"
    ["NGINX_CERT"]="./${domain}_origin_cert.pem"
    ["NGINX_KEY"]="./${domain}_origin_key.pem"
    ["HOST_ENV"]="$HOST_ENV"
    ["VERSION"]="$VERSION"
    ["GOOGLE_MAPS_KEY"]="$GOOGLE_MAPS_KEY"
    ["PUBLIC_POSTHOG_KEY"]="$publicposthogkey"
    ["PUBLIC_POSTHOG_HOST"]="$PUBLIC_POSTHOG_HOST"
    ["GA_TRACKING_ID"]="$gatrackingid"
    ["CLIENT_HEADER"]="$CLIENT_HEADER"
    ["SENGRID_KEY"]="$SENGRID_KEY"
    ["GITHUB_PAT"]="$GITHUB_PAT"
    ["SOCIAL_META"]="$socialmeta"
    ["SEQUENCE_LIMIT"]="$sequencelimit"
  )

  # Print all answers before asking to update the .env file
  echo
  echo "Please confirm the values below are correct:"
  echo
  echo "--------------------------------"
  # Iterate over the original order of keys
  for key in "${original_keys[@]}"; do
    if [[ -n "${new_env_vars[$key]}" ]]; then
      echo "$key=${new_env_vars[$key]}"
    fi
  done
  echo "--------------------------------"
  echo

  # Write the variables to the .env file if answer is y
  if [[ "$(get_input "Update the .env file with the above values? (y/n)" "n" )" =~ ^[Yy]$ ]]; then
    # Backup the existing .env file
    cp .env .env.bak 2>/dev/null || echo "No existing .env file to back up."

    # Update the .env file
    for key in "${!new_env_vars[@]}"; do
      if [[ -n "${existing_env_vars[$key]}" ]]; then
        # Update existing variable
       # echo "Updating existing .env variable ${key}=${new_env_vars[$key]}"
        sed -i "s|^${key}=.*|${key}=${new_env_vars[$key]}|" .env
      else
        # Append new variable
       # echo "Appending new .env variable ${key}=${new_env_vars[$key]}"
        echo "${key}=${new_env_vars[$key]}" >> .env
      fi
    done
    echo "Writing variables to .env file completed!"
    echo
  else
    echo "Variables were not updated! No changes were made to the .env file"
    echo
  fi
}

# Check if user is root or in the sudo group
if [[ $EUID -eq 0 ]]; then
  # User is root, do nothing
  :
elif id -nG "$USER" | grep -qw "sudo"; then
  # User is in the sudo group, do nothing
  :
else
  echo "User '$USER' is NOT root and NOT part of the sudo group."
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
          echo "Docker install failed. Please install Docker to proceed."
          exit 1
        else
          echo "Docker installation for Ubuntu complete!"
        fi
      ;;
      debian)
        echo "Installing Docker for Debian.."
        sudo apt-get update && sudo apt-get install ca-certificates curl && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        if [ ! -x "$(command -v docker)" ]; then
          echo "Docker install failed. Please install Docker to proceed."
          exit 1
        else
          echo "Docker installation for Debian complete!"
        fi
      ;;
      *) echo "Distribution is not supported by this script! Please install Docker manually."
      ;;
    esac
  else
    echo "Docker must be installed. Please re-run the script to install Docker and to proceed."
    exit 1
  fi
  echo
fi

# Download extra helper scripts if they do not exist and make them executable
download_file $UPDATE_RF_CONTAINERS_URL "update_rf_containers.sh"
chmod +x "update_rf_containers.sh"
download_file $UPDATE_CONTAINERS_URL "update_containers.sh"
chmod +x "update_containers.sh"
download_file $HEALTH_CHECK_URL "health_check.sh"
chmod +x "health_check.sh"

# Ensure the 'remotefalcon' directory exists
if [ ! -d "$WORKING_DIR" ]; then
  echo "Directory '$RF_DIR' does not exist. Creating it in $SCRIPT_DIR..."
  mkdir "$WORKING_DIR"
fi

# Change to the 'remotefalcon' directory
cd "$WORKING_DIR" || { echo "Failed to change directory to '$WORKING_DIR'. Exiting."; exit 1; }
echo "Working in directory: $(pwd)"

# Download compose.yaml and NGINX default.conf in the working directory if they do not exist
download_file $DOCKER_COMPOSE_URL "compose.yaml"
download_file $NGINX_DEFAULT_URL "default.conf"

# Print existing .env file, if it exists, otherwise download the default .env file
echo "Checking for existing .env file for environmental variables..."
if [ -f .env ]; then
  echo "Source .env exists!"
  echo "Printing current .env variables:"
  parse_env
else
  download_file $DEFAULT_ENV_URL ".env"
  echo "Printing default .env variables:"
  parse_env
fi

# Ask to configure .env values
if [[ "$(get_input "Change the .env file variables? (y/n)" "n" )" =~ ^[Yy]$ ]]; then
  # Configuration walkthrough questions. Questions will pull existing or default values from the sourced .env file
  echo
  echo "Answer the following questions to update your compose .env variables."
  echo "Press ENTER to accept the existing values that are between the brackets [ ]."
  echo "You will be asked to confirm the changes before the file is modified."
  echo
  tunneltoken=$(get_input "Enter your Cloudflare tunnel token:" "$TUNNEL_TOKEN")
  echo
  domain=$(get_input "Enter your domain name, example: yourdomain.com:" "$DOMAIN")
  echo
  viewerjwtkey=$(get_input "Enter a random value for viewer JWT key:" "$VIEWER_JWT_KEY")
  echo
  # Removed this question to avoid issues - .env can be manually edited if you have ACM and want a 3 part domain.
  #echo "Enter the number of parts in your hostname. For example, domain.com would be two parts ('domain' and 'com'), and sub.domain.com would be 3 parts ('sub', 'domain', and 'com')"
  #hostnameparts=$(get_input "Cloudflare free only supports two parts for wildcard domains without Advanced Certicate Manager(\$10/month):" "$HOSTNAME_PARTS" )
  #echo
  hostnameparts=2
  autovalidateemail=$(get_input "Enable auto validate email? While set to 'true' anyone can create a viewer page account on your site (true/false):" "$AUTO_VALIDATE_EMAIL")
  echo

  # Ask if Cloudflare origin certificates should be updated. This will create the cert/key in the current directory and append the domain name to the beginning of the file name
  if [[ "$(get_input "Update origin certificates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
    read -p "Press any key to open nano to paste the origin certificate. Ctrl+X, y, and Enter to save."
    nano ${domain}_origin_cert.pem
    read -p "Press any key to open nano to paste the origin private key. Ctrl+X, y, and Enter to save."
    nano ${domain}_origin_key.pem
  fi
  echo

  # Ask if analytics env variables should be set for PostHog and Google Analytics
  if [[ "$(get_input "Update analytics variables? (y/n)" "n")" =~ ^[Yy]$ ]]; then
    read -p "Enter your PostHog key - https://posthog.com/: [$PUBLIC_POSTHOG_KEY]: " publicposthogkey
    read -p "Enter your Google Analytics Measurement ID - https://analytics.google.com/: [$GA_TRACKING_ID]: " gatrackingid
  fi

  publicposthogkey=${publicposthogkey:-$PUBLIC_POSTHOG_KEY}
  gatrackingid=${gatrackingid:-$GA_TRACKING_ID}
  echo

  # Ask if SOCIAL_META variable should be updated
  if [[ "$(get_input "Update social meta tag? (y/n)" "n")" =~ ^[Yy]$ ]]; then
    echo "See the RF docs for details on the SOCIAL_META tag:"
    echo "https://docs.remotefalcon.com/docs/developer-docs/running-it/digitalocean-droplet?#update-docker-composeyaml"
    echo
    echo "Update SOCIAL_META tag or leave as default - Enter on one line only"
    echo
    read -p "[$SOCIAL_META]: " socialmeta
  fi
  socialmeta=${socialmeta:-$SOCIAL_META}
  echo

  sequencelimit=$(get_input "Enter desired sequence limit:" "$SEQUENCE_LIMIT")

  # Display updated variables and ask to write them to the .env file
  update_env

  # Parse/print variables again to allow for checking the $DOMAIN variable later
  echo "Printing current .env variables:"
  parse_env
else
  echo "No .env variables modified."
  echo
fi

# Run the container update scripts if the domain isn't the default value
if [[ "$DOMAIN" != "your_domain.com" ]]; then
  bash "$SCRIPT_DIR/update_containers.sh" "mongo" --no-health # Start with Mongo first since the RF containers depend on it.
  bash "$SCRIPT_DIR/update_rf_containers.sh" --no-health
  bash "$SCRIPT_DIR/update_containers.sh" "nginx" --no-health
  bash "$SCRIPT_DIR/update_containers.sh" "cloudflared" --no-health
else
  echo "DOMAIN is still set to the default '$DOMAIN' domain. Re-run the configure-rf.sh script to modify the default .env values."
  exit 1
fi

bash "$SCRIPT_DIR/health_check.sh"
echo "Done! Exiting RF configuration script..."
exit 0

# Update script to hanlde missing files instead of creating the file with these contents: 404: Not Found
#Working in directory: /home/travisd/1_4_2025_test/remotefalcon
#compose.yaml does not exist. Downloading compose.yaml...
#  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
#                                 Dload  Upload   Total   Spent    Left  Speed
#100    14  100    14    0     0     93      0 --:--:-- --:--:-- --:--:--    93
#Downloaded compose.yaml successfully.
#default.conf does not exist. Downloading default.conf...
#  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
#                                 Dload  Upload   Total   Spent    Left  Speed
#100    14  100    14    0     0     84      0 --:--:-- --:--:-- --:--:--    85
#Downloaded default.conf successfully.
#Checking for existing .env file for environmental variables...
#.env does not exist. Downloading .env...
#  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
#                                 Dload  Upload   Total   Spent    Left  Speed
#100    14  100    14    0     0     91      0 --:--:-- --:--:-- --:--:--    92
#Downloaded .env successfully.
#Printing default .env variables:
#
#--------------------------------
#--------------------------------