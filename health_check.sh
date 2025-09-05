#!/bin/bash

# VERSION=2025.9.5.1

#set -euo pipefail
#set -x

SERVICES=(external-api ui plugins-api viewer control-panel cloudflared nginx mongo minio)
HEALTHY=true
SLEEP_TIME="${1:-}" # Optional sleep time in seconds, defaults to 20s if not provided
MAX_RETRIES=3 # Max retries for checking RF endpoints
RETRY_DELAY=5  # Seconds to wait between retries


if [[ -z "$SLEEP_TIME" ]]; then
  SLEEP_TIME="10s"  # Default to 20s if not provided
fi

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/shared_functions.sh" ]]; then
  echo -e "${RED}❌ ERROR: shared_functions.sh does not exist in $SCRIPT_DIR.${NC}"
  exit 1
fi

source "$SCRIPT_DIR/shared_functions.sh"


# Define known error patterns and custom messages
declare -A CONTAINER_PATTERNS

# Format: "pattern|custom message"
CONTAINER_PATTERNS["cloudflared"]='
Error response from daemon: No such container|Container is not running
certificate is valid for|Verify Origin certificate and Tunnel Public Hostname configuration includes *.yourdomain.com.
Provided Tunnel token is not valid.|Verify that your Cloudflare tunnel token is correct.
'

CONTAINER_PATTERNS["nginx"]='
Error response from daemon: No such container|Container is not running
connect() failed (111: Connection refused) while connecting to upstream|NGINX cannot connect to RF containers. Try restarting NGINX container or all containers.
'

CONTAINER_PATTERNS["mongo"]='
Error response from daemon: No such container|Container is not running
requires a CPU with AVX support|Check that your CPU supports AVX, if running in VM try changing VM CPU to 'host' type.
'

CONTAINER_PATTERNS["remote-falcon-images.minio"]='
Error response from daemon: No such container|Container is not running
'

CONTAINER_PATTERNS["external-api"]='
Error response from daemon: No such container|Container is not running
'

CONTAINER_PATTERNS["plugins-api"]='
Error response from daemon: No such container|Container is not running
'

CONTAINER_PATTERNS["viewer"]='
Error response from daemon: No such container|Container is not running
'

CONTAINER_PATTERNS["control-panel"]='
Error response from daemon: No such container|Container is not running
'

CONTAINER_PATTERNS["ui"]='
Error response from daemon: No such container|Container is not running
'

# Function to check logs with custom messages
check_container_logs() {
  local container="$1"
  local logs
  logs=$(sudo docker logs --tail 50 "$container" 2>&1)

  echo -e "🔍 Checking logs for ${BLUE}$container${NC}..."

  local found=false
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue  # skip blanks
    local pattern="${entry%%|*}"
    local message="${entry#*|}"

    if echo "$logs" | grep -qE "$pattern"; then
      echo -e "❌ ${RED}Error detected:${NC} $message"
      echo -e "   ↳ ${YELLOW}Log snippet:${NC}"
      echo "$logs" | grep -E "$pattern" | tail -5 | sed 's/^/      /'
      found=true
      HEALTHY=false
    fi
  done <<< "${CONTAINER_PATTERNS[$container]}"

  if [[ $found == false ]]; then
    echo -e "✅ ${GREEN}No known issues detected in $container logs.${NC}"
  fi
}

# Run all containers
check_all_containers() {
  for container in "${!CONTAINER_PATTERNS[@]}"; do
    check_container_logs "$container"
  done
}

# Function to check if container is running using compose 'service' name instead of 'container_name'
is_container_running() {
  local service="$1"
  sudo docker compose -f "$COMPOSE_FILE" ps --services --filter "status=running" | grep -q "^$service$"
}

echo -e "${BLUE}⚙️ Running health check script...${NC}"
#echo "Sleeping $SLEEP_TIME before running health checks..."
#sleep $SLEEP_TIME
#sudo docker ps -a
#echo
#echo "Verify that all containers show 'running OR Up'. If not, check logs with 'sudo docker logs <container_name>' or try 'sudo docker compose -f "$COMPOSE_FILE" up -d'"
all_services_running=true

for service in "${SERVICES[@]}"; do
  if ! is_container_running $service; then
    all_services_running=false
  fi
done
#if [[ $all_services_running == false ]]; then
echo "💤 Sleeping $SLEEP_TIME before running health checks..."
sleep $SLEEP_TIME
#fi

# Check if env file exists, parse it, then check if domain is not yourdomain.com
# Then run various health checks
if [[ -f $ENV_FILE ]]; then
  parse_env $ENV_FILE

  # Check if DOMAIN is set
  if [[ -z "$DOMAIN" || "$DOMAIN" == "your_domain.com" ]]; then
    echo -e "${RED}❌ Error: DOMAIN is not set in the .env file.${NC}"
    HEALTHY=false
    #exit 1
  fi

  # Check each RF container endpoint to get its status or HTTP response code
  # Array of RF containers and endpoints
  declare -A rf_containers=(
    ["control-panel"]="https://$DOMAIN/remote-falcon-control-panel/actuator/health/"
    ["ui"]="https://$DOMAIN/health.json"
    ["viewer"]="https://$DOMAIN/remote-falcon-viewer/q/health"
#    ["plugins-api"]="https://$DOMAIN/remote-falcon-plugins-api/actuator/health/"
    ["plugins-api"]="https://$DOMAIN/remote-falcon-plugins-api/q/health"
    ["external-api"]="https://$DOMAIN/remote-falcon-external-api/actuator/health/"
  )

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}🔄 Checking Remote Falcon endpoints...${NC}"

  # Iterate through each container and its endpoint if it is running
  for rf_container in "${!rf_containers[@]}"; do
    endpoint="${rf_containers[$rf_container]}"

    if ! is_container_running "$rf_container"; then
      echo -e "${RED}❌ $rf_container is NOT running.${NC}"
      HEALTHY=false
      continue
    else
      # Fetch the response and HTTP status code
      response=$(curl -s -o /tmp/curl_response -w "%{http_code}" "$endpoint")
      http_code=$response
      body=$(cat /tmp/curl_response)

      # Extract the "status" field from the JSON-like response (handles compact and formatted JSON)
      status=$(echo "$body" | grep -o '"status":[ ]*"UP"' | head -n1 | sed 's/.*"status":[ ]*"\([^"]*\)".*/\1/' || true)

      # Check if the status is "UP" or handle errors
      if [[ "$http_code" -eq 200 && "$status" == "UP" ]]; then
          echo -e "  ${YELLOW}•${NC} ${GREEN}✅ $rf_container endpoint ${BLUE}🔗 $endpoint${NC} ${GREEN}status is UP${NC}"
      else
        # Retry loop
        attempt=1
        while true; do
          # Fetch the response and HTTP status code
          response=$(curl -s -o /tmp/curl_response -w "%{http_code}" "$endpoint")
          http_code=$response
          body=$(cat /tmp/curl_response)

          # Extract the "status" field from the JSON-like response (handles compact and formatted JSON)
          status=$(echo "$body" | grep -o '"status":[ ]*"UP"' | head -n1 | sed 's/.*"status":[ ]*"\([^"]*\)".*/\1/' || true)

          # Check if the status is "UP" or handle errors
          if [[ "$http_code" -eq 200 && "$status" == "UP" ]]; then
            echo -e "  ${YELLOW}•${NC} ${GREEN}✅ $rf_container endpoint ${BLUE}🔗 $endpoint${NC} ${GREEN}status is UP${NC}"
            break  # Success, exit retry loop
          else
            if [[ $attempt -lt $MAX_RETRIES ]]; then
              echo -e "${YELLOW}⚠️ $rf_container endpoint status check attempt ($attempt/$MAX_RETRIES) failed. Retrying in $RETRY_DELAY seconds...${NC}"
              sleep $RETRY_DELAY
              ((attempt++))
            else
              # Final failure after retries
              if [[ "$http_code" -ne 200 ]]; then
                echo -e "  ${YELLOW}•${NC} ${RED}❌ $rf_container HTTP Error: $http_code (Endpoint ${BLUE}🔗 $endpoint${NC} ${RED}may be down)${NC}"
              else
                echo -e "  ${YELLOW}•${NC} ${RED}❌ $rf_container endpoint ${BLUE}🔗 $endpoint${NC} ${RED}status is NOT UP (Current status: $status)${NC}"
                echo -e "${YELLOW}⚠️ Check the logs with 'sudo docker logs $rf_container' for more information.${NC}"
              fi
              break  # Give up after max retries
            fi
          fi
        done
      fi
    fi
  done
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Check if the cert or the key do not exist and exit, else validate the cert and key with openssl
  echo -e "${CYAN}🔄 Checking certificate '$NGINX_CERT' and private key '$NGINX_KEY' file...${NC}"
  if [[ ! -f "$WORKING_DIR/$NGINX_CERT" || ! -f "$WORKING_DIR/$NGINX_KEY" ]]; then
    echo -e "${RED}❌ Error: Certificate or private key file not found:${NC}"
    HEALTHY=false
    echo -e "  ${YELLOW}•${NC} Certificate: "$WORKING_DIR/$NGINX_CERT""
    echo -e "  ${YELLOW}•${NC} Private key: "$WORKING_DIR/$NGINX_KEY""
  else
    # Extract the public key from the certificate
    cert_pub_key=$(openssl x509 -in "$NGINX_CERT" -pubkey -noout 2>/dev/null || true)

    # Extract the public key from the private key
    key_pub_key=$(openssl rsa -in "$NGINX_KEY" -pubout 2>/dev/null || true)

    # Compare the public keys
    if [[ "$cert_pub_key" == "$key_pub_key" ]]; then
      echo -e "${GREEN}✅ The certificate and private key match.${NC}"
    else
      echo -e "${RED}❌ The certificate and private key do NOT match:${NC}"
      HEALTHY=false
      echo -e "  ${YELLOW}•${NC} Certificate: "$WORKING_DIR/$NGINX_CERT""
      echo -e "  ${YELLOW}•${NC} Private key: "$WORKING_DIR/$NGINX_KEY""
    fi
  fi

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  container_name="nginx"

  # Check if the nginx container is running and test its configuration
  if is_container_running $container_name; then
    echo -e "${CYAN}🔄 $container_name is running. Testing the configuration with 'sudo docker exec $container_name nginx -t'...${NC}"
    nginx_test_output=$(sudo docker exec $container_name nginx -t 2>&1)
    echo "$nginx_test_output"
    if echo "$nginx_test_output" | grep -q "syntax is ok" && echo "$nginx_test_output" | grep -q "test is successful"; then
      echo -e "${GREEN}✅ NGINX configuration test successful.${NC}"
    else
      echo -e "${RED}❌ NGINX configuration test FAILED. Check default.conf${NC}"
    fi
  else
    echo -e "${RED}❌ $container_name is NOT running.${NC}"
    HEALTHY=false
  fi

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  container_name="minio"

  # Check if the minio container is running
  if is_container_running $container_name; then
    echo -e "${CYAN}🔄 $container_name is running. Checking the status of the MinIO server...${NC}"
    lan_ip=$(ip route get 1 | awk '/src/ { for(i=1;i<=NF;i++) if ($i=="src") print $(i+1) }')
    echo -e "MinIO Console: ${BLUE}🔗 http://$lan_ip:9001${NC}"

    ALIAS_CMD="mc alias set $MINIO_ALIAS $S3_ENDPOINT $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD"
    sudo docker compose -f "$COMPOSE_FILE" exec "$container_name" $ALIAS_CMD
    sudo docker compose -f "$COMPOSE_FILE" exec "$container_name" mc admin info $MINIO_ALIAS
    echo
    # Print bucket and object information
    echo "Checking bucket '$BUCKET_NAME' and object information..."
    #sudo docker compose -f "$COMPOSE_FILE" exec "$container_name" mc du --recursive $MINIO_ALIAS
    output=$(sudo docker compose -f "$COMPOSE_FILE" exec "$container_name" mc du --recursive "$MINIO_ALIAS" 2>/dev/null || true)
    echo "$output"
    if echo "$output" | grep -qE '\bremote-falcon-images\b'; then
      echo -e "${GREEN}✅ Bucket '$BUCKET_NAME' found in $container_name.${NC}"
    else
      echo -e "${RED}❌ Bucket '$BUCKET_NAME' not found in $container_name. Re-run ./minio_init.sh${NC}"
    fi

    if sudo docker compose -f "$COMPOSE_FILE" exec "$container_name" mc anonymous get "$MINIO_ALIAS/$BUCKET_NAME" | grep -q "Access permission.*is.*public"; then
      echo -e "${GREEN}✅ Bucket '$BUCKET_NAME' is public.${NC}"
    else
      echo -e "${RED}❌ Bucket '$BUCKET_NAME' is NOT public.${NC}"
    fi
    # Get the non-expiring access key (expiration == 1970-01-01T00:00:00Z)
    minio_3_access_key=$(sudo docker compose -f "$COMPOSE_FILE" exec $container_name mc admin accesskey ls --json $MINIO_ALIAS \
      | grep -B3 '"expiration":"1970-01-01T00:00:00Z"' \
      | grep '"accessKey"' \
      | head -n1 \
      | sed -E 's/.*"accessKey":"([^"]+)".*/\1/')

    # Compare to the S3_SECRET_KEY
    if [[ "$minio_3_access_key" == "$S3_ACCESS_KEY" ]]; then
      echo -e "${GREEN}✅ S3 access key matches S3_ACCESS_KEY in $ENV_FILE.${NC}"
    else
      echo -e "${RED}❌ S3 access key does NOT match S3_ACCESS_KEY in $ENV_FILE.${NC}"
      echo -e "${YELLOW}MinIO Key: ${minio_3_access_key}${NC}"
      echo -e "${YELLOW}S3_ACCESS_KEY: ${S3_ACCESS_KEY}${NC}"
    fi

    # Verify control-panel has a valid S3_ACCESS_KEY
    if sudo docker logs control-panel 2>&1 | grep -q "InvalidAccessKeyId"; then
      echo -e "${RED}❌ control-panel is reporting InvalidAccessKeyId. You may want to re-run ./minio_init.sh to correct this.${NC}"
    fi


   # sudo docker compose -f "$COMPOSE_FILE" exec "$container_name" mc ls --summarize --recursive $MINIO_ALIAS
  else
    echo -e "${RED}❌ $container_name is NOT running.${NC}"
  fi

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  container_name="mongo"

  # If mongo exists, display show subdomain details from mongo in the format of https://subdomain.yourdomain.com
  if is_container_running $container_name; then
    echo -e "${CYAN}🔄 $container_name is running. 🔍 Finding any shows in MongoDB container '$container_name'...${NC}"

    subdomains=$(sudo docker exec mongo bash -c "
    mongosh --quiet 'mongodb://root:root@localhost:27017' --eval '
        db = db.getSiblingDB(\"remote-falcon\");
        const subdomains = db.show.find({}, { showSubdomain: 1, _id: 0 }).toArray();
        let found = false;
        subdomains.forEach(doc => {
            if (doc.showSubdomain) {
                print(doc.showSubdomain);
                found = true;
            }
        });
        if (!found) {
            print(\"No subdomains found\");
        }
    '")

    if [[ "$subdomains" == *"No subdomains found"* ]]; then
      echo -e "${YELLOW}⚠️ No shows have been configured in ${NC}${RED}Remote Falcon${NC}${YELLOW}. Create a new account at:${NC} ${BLUE}🔗 https://$DOMAIN/signup${NC}"
    else
        while read -r subdomain; do
          echo -e "  ${YELLOW}•${NC} ${BLUE}🔗 https://$subdomain.$DOMAIN${NC}"
        done <<< "$subdomains"
    fi
  else
    echo -e "${RED}❌ $container_name is NOT running.${NC}"
    HEALTHY=false
  fi
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  check_all_containers
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  if [[ $HEALTHY == true ]]; then
    if [[ $SWAP_CP == true ]]; then
      echo -e "${CYAN}🔄 SWAP_CP is enabled! Checking if Viewer Page Subdomain exists in MongoDB...${NC}"
      if echo "$subdomains" | grep -Fxq "$VIEWER_PAGE_SUBDOMAIN"; then
        echo -e "${GREEN}✅ Viewer Page Subdomain ${YELLOW}$VIEWER_PAGE_SUBDOMAIN${GREEN} found in MongoDB.${NC}"
        echo -e "  ${YELLOW}•${NC} If everything is running properly, ${BLUE}🔗 https://$VIEWER_PAGE_SUBDOMAIN.$DOMAIN${NC} is accessible at: ${BLUE}🔗 https://$DOMAIN${NC}"
      else
        echo -e "  ${YELLOW}•${NC} ${RED}❌ Viewer Page Subdomain ${YELLOW}$VIEWER_PAGE_SUBDOMAIN${RED} is not found in MongoDB! You must create a show named ${YELLOW}$VIEWER_PAGE_SUBDOMAIN${RED} for it to be accessible at: ${BLUE}🔗 https://$DOMAIN${NC}"
      fi
      echo -e "  ${YELLOW}•${NC} The ${RED}Remote Falcon${NC} Control Panel is accessible at: ${BLUE}🔗 https://controlpanel.$DOMAIN${NC}"
    else
      echo -e "SWAP_CP is disabled."
      echo -e "If everything is running properly, ${RED}Remote Falcon${NC} is accessible at: ${BLUE}🔗 https://$DOMAIN${NC}"
    fi
  else
    echo -e "${RED}❌ Error: Some services are NOT running properly!${NC}"
    echo -e "${YELLOW}⚠️ Check logs with 'sudo docker logs <container_name>' or try 'sudo docker compose -f "$COMPOSE_FILE" down' and 'sudo docker compose -f "$COMPOSE_FILE" up -d'${NC}"
  fi
else
    echo -e "${RED}❌ Error: $ENV_FILE file not found.${NC}"
fi

exit 0