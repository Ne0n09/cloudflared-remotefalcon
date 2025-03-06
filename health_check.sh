#!/bin/bash

SCRIPT_VERSION=2025.3.6.1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RF_DIR="remotefalcon"
WORKING_DIR="$SCRIPT_DIR/$RF_DIR"
ENV_FILE="$WORKING_DIR/.env"
SLEEP_TIME=20s

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

echo
echo "Running health check script..."
echo "Sleeping $SLEEP_TIME before running 'sudo docker ps -a' to verify the status of all containers."
sleep $SLEEP_TIME
echo
echo "'sudo docker ps -a':"
sudo docker ps -a
echo
echo "Verify that all containers show 'running OR Up'. If not, check logs with 'sudo docker logs <container_name>' or try 'sudo docker compose up -d'"
echo


# Check if env file exists, parse it, then check if domain is not yourdomain.com
# Then run various health checks
if [[ -f $ENV_FILE ]]; then
  parse_env

  # Check if DOMAIN is set
  if [[ -z "$DOMAIN" || "$DOMAIN" == "your_domain.com"  ]]; then
    echo "Error: DOMAIN is not set in the .env file."
    exit 1
  fi

  # Check each RF container endpoint to get its status or HTTP response code
  # Array of RF containers and endpoints
  declare -A containers=(
    ["control-panel"]="https://$DOMAIN/remote-falcon-control-panel/actuator/health/"
    ["ui"]="https://$DOMAIN/health.json"
    ["viewer"]="https://$DOMAIN/remote-falcon-viewer/q/health"
    ["plugins-api"]="https://$DOMAIN/remote-falcon-plugins-api/actuator/health/"
    ["external-api"]="https://$DOMAIN/remote-falcon-external-api/actuator/health/"
  )

  echo "Checking Remote Falcon endpoints..."

  # Iterate through each container and its endpoint
  for container in "${!containers[@]}"; do
    endpoint="${containers[$container]}"

    # Fetch the response and HTTP status code
    response=$(curl -s -o /tmp/curl_response -w "%{http_code}" "$endpoint")
    http_code=$response
    body=$(cat /tmp/curl_response)

    # Extract the "status" field from the JSON-like response (handles compact and formatted JSON)
    status=$(echo "$body" | grep -o '"status":[ ]*"UP"' | head -n1 | sed 's/.*"status":[ ]*"\([^"]*\)".*/\1/')

    # Check if the status is "UP" or handle errors
    if [[ "$http_code" -eq 200 && "$status" == "UP" ]]; then
        echo -e "✅ Container '$container' endpoint '$endpoint' status is UP"
    else
        if [[ "$http_code" -ne 200 ]]; then
            echo -e "❌ Container '$container' HTTP Error: $http_code (Endpoint '$endpoint' may be down)"
        else
            echo -e "❌ Container '$container' endpoint ''$endpoint'' status is NOT UP (Current status: $status)"
            echo "Check the logs with 'sudo docker logs $container' for more information."
        fi
    fi
  done
  echo

  # Check if the cert or the key do not exist and exit, else validate the cert and key with openssl
  echo "Checking certificate '$NGINX_CERT' and private key '$NGINX_KEY' file..."
  if [[ ! -f "$WORKING_DIR/$NGINX_CERT" || ! -f "$WORKING_DIR/$NGINX_KEY" ]]; then
    echo "Error: Certificate or private key file not found."
    echo "$WORKING_DIR/$NGINX_CERT"
    echo "$WORKING_DIR/$NGINX_KEY"
  else
    # Extract the public key from the certificate
    cert_pub_key=$(openssl x509 -in "$NGINX_CERT" -pubkey -noout 2>/dev/null)

    # Extract the public key from the private key
    key_pub_key=$(openssl rsa -in "$NGINX_KEY" -pubout 2>/dev/null)

    # Compare the public keys
    if [[ "$cert_pub_key" == "$key_pub_key" ]]; then
      echo "✅ The certificate and private key match."
    else
      echo "❌ The certificate and private key do NOT match."
      echo "Certificate: "$WORKING_DIR/$NGINX_CERT""
      echo "Private key: "$WORKING_DIR/$NGINX_KEY""
    fi
  fi

  echo
  container_name="nginx"

  # Check if the nginx container is running and test its configuration
  if sudo docker ps --filter "name=$container_name" --filter "status=running" --format "{{.Names}}" | grep -q "^$container_name$"; then
    echo "The container '$container_name' is running. Testing the configuration with 'sudo docker exec $container_name nginx -t'..."
    sudo docker exec $container_name nginx -t
  else
    echo "❌ The container '$container_name' is NOT running."
  fi
echo
  container_name="mongo"

  # If mongo exists, display show subdomain details from mongo in the format of https://subdomain.yourdomain.com
  if sudo docker ps --filter "name=$container_name" --filter "status=running" --format "{{.Names}}" | grep -q "^$container_name$"; then
    echo "The container '$container_name' is running. Finding any shows in Mongo container '$container_name'..."

    subdomains=$(sudo docker exec -it mongo bash -c "
    mongosh --quiet 'mongodb://root:root@localhost:27017' --eval '
        db = db.getSiblingDB(\"remote-falcon\");
        const subdomains = db.show.find({}, { showSubdomain: 1, _id: 0 }).toArray();
        let found = false;
        subdomains.forEach(doc => {
            if (doc.showSubdomain) {
                print(\"https://\" + doc.showSubdomain + \".$DOMAIN\");
                found = true;
            }
        });
        if (!found) {
            print(\"No subdomains found\");
        }
    '")

    if [[ "$subdomains" == *"No subdomains found"* ]]; then
      echo "No shows have been configured in Remote Falcon. Create a new account at: https://$DOMAIN.com/signup"
    else
      echo "$subdomains"
    fi
  else
    echo "❌ The container '$container_name' is NOT running."
  fi

  echo
  echo "If everything is running properly, Remote Falcon should be accessible at: https://$DOMAIN"
else
    echo "Error: $ENV_FILE file not found."
fi

exit 0