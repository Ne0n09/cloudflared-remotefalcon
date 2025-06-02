#!/bin/bash

# VERSION=2025.6.2.1

#set -euo pipefail
#set -x

SLEEP_TIME=20s

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/shared_functions.sh" ]]; then
  echo -e "${RED}❌ ERROR: shared_functions.sh does not exist in $SCRIPT_DIR.${NC}"
  exit 1
fi

source "$SCRIPT_DIR/shared_functions.sh"

echo -e "${BLUE}⚙️ Running health check script...${NC}"
echo "Sleeping $SLEEP_TIME before running 'sudo docker ps -a' to verify the status of all containers."
sleep $SLEEP_TIME
sudo docker ps -a
echo
echo "Verify that all containers show 'running OR Up'. If not, check logs with 'sudo docker logs <container_name>' or try 'sudo docker compose -f "$COMPOSE_FILE" up -d'"

# Check if env file exists, parse it, then check if domain is not yourdomain.com
# Then run various health checks
if [[ -f $ENV_FILE ]]; then
  parse_env $ENV_FILE

  # Check if DOMAIN is set
  if [[ -z "$DOMAIN" || "$DOMAIN" == "your_domain.com" ]]; then
    echo -e "${RED}❌ Error: DOMAIN is not set in the .env file.${NC}"
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

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}🔄 Checking Remote Falcon endpoints...${NC}"

  # Iterate through each container and its endpoint
  for container in "${!containers[@]}"; do
    endpoint="${containers[$container]}"

    # Fetch the response and HTTP status code
    response=$(curl -s -o /tmp/curl_response -w "%{http_code}" "$endpoint")
    http_code=$response
    body=$(cat /tmp/curl_response)

    # Extract the "status" field from the JSON-like response (handles compact and formatted JSON)
    status=$(echo "$body" | grep -o '"status":[ ]*"UP"' | head -n1 | sed 's/.*"status":[ ]*"\([^"]*\)".*/\1/' || true)

    # Check if the status is "UP" or handle errors
    if [[ "$http_code" -eq 200 && "$status" == "UP" ]]; then
        echo -e "  ${YELLOW}•${NC} ${GREEN}✅ $container endpoint ${BLUE}🔗 $endpoint${NC} ${GREEN}status is UP${NC}"
    else
        if [[ "$http_code" -ne 200 ]]; then
            echo -e "  ${YELLOW}•${NC} ${RED}❌ $container HTTP Error: $http_code (Endpoint ${BLUE}🔗 $endpoint${NC} ${RED}may be down)${NC}"
        else
            echo -e "  ${YELLOW}•${NC} ${RED}❌ $container endpoint ${BLUE}🔗 $endpoint${NC} ${RED}status is NOT UP (Current status: $status)${NC}"
            echo -e "${YELLOW}⚠️ Check the logs with 'sudo docker logs $container' for more information.${NC}"
        fi
    fi
  done
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Check if the cert or the key do not exist and exit, else validate the cert and key with openssl
  echo -e "${CYAN}🔄 Checking certificate '$NGINX_CERT' and private key '$NGINX_KEY' file...${NC}"
  if [[ ! -f "$WORKING_DIR/$NGINX_CERT" || ! -f "$WORKING_DIR/$NGINX_KEY" ]]; then
    echo -e "${RED}❌ Error: Certificate or private key file not found.${NC}"
    echo "$WORKING_DIR/$NGINX_CERT"
    echo "$WORKING_DIR/$NGINX_KEY"
  else
    # Extract the public key from the certificate
    cert_pub_key=$(openssl x509 -in "$NGINX_CERT" -pubkey -noout 2>/dev/null || true)

    # Extract the public key from the private key
    key_pub_key=$(openssl rsa -in "$NGINX_KEY" -pubout 2>/dev/null || true)

    # Compare the public keys
    if [[ "$cert_pub_key" == "$key_pub_key" ]]; then
      echo -e "${GREEN}✅ The certificate and private key match.${NC}"
    else
      echo -e "${RED}❌ The certificate and private key do NOT match.${NC}"
      echo -e "  ${YELLOW}•${NC} Certificate: "$WORKING_DIR/$NGINX_CERT""
      echo -e "  ${YELLOW}•${NC} Private key: "$WORKING_DIR/$NGINX_KEY""
    fi
  fi

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  container_name="nginx"

  # Check if the nginx container is running and test its configuration
  if sudo docker ps --filter "name=$container_name" --filter "status=running" --format "{{.Names}}" | grep -q "^$container_name$"; then
    echo -e "${CYAN}🔄 $container_name is running. Testing the configuration with 'sudo docker exec $container_name nginx -t'...${NC}"
    sudo docker exec $container_name nginx -t
  else
    echo -e "${RED}❌ $container_name is NOT running.${NC}"
  fi

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  container_name="remote-falcon-images.minio"

  # Check if the minio container is running
  if sudo docker ps --filter "name=$container_name" --filter "status=running" --format "{{.Names}}" | grep -q "^$container_name$"; then
    echo -e "${CYAN}🔄 $container_name is running. Checking the status of the MinIO server...${NC}"
    lan_ip=$(ip route get 1 | awk '/src/ { for(i=1;i<=NF;i++) if ($i=="src") print $(i+1) }')
    echo -e "MinIO Console: ${BLUE}🔗 http://$lan_ip:9001${NC}"

    ALIAS_CMD="mc alias set $MINIO_ALIAS $S3_ENDPOINT $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD"
    sudo docker exec "$container_name" $ALIAS_CMD
    sudo docker exec "$container_name" mc admin info $MINIO_ALIAS
    echo
    # Print bucket and object information
    echo "Checking bucket '$BUCKET_NAME' and object information..."
    #sudo docker exec "$container_name" mc du --recursive $MINIO_ALIAS
    output=$(sudo docker exec "$container_name" mc du --recursive "$MINIO_ALIAS" 2>/dev/null || true)
    echo "$output"
    if echo "$output" | grep -qE '\bremote-falcon-images\b'; then
      echo -e "${GREEN}✅ Bucket '$BUCKET_NAME' found in $container_name${NC}"
    else
      echo -e "${RED}❌ Bucket '$BUCKET_NAME' not found in $container_name. Re-run ./minio_init.sh${NC}"
    fi

    if sudo docker exec "$container_name" mc anonymous get "$MINIO_ALIAS/$BUCKET_NAME" | grep -q "Access permission.*is.*public"; then
      echo -e "${GREEN}✅ Bucket '$BUCKET_NAME' is public.${NC}"
    else
      echo -e "${RED}❌ Bucket '$BUCKET_NAME' is NOT public.${NC}"
    fi
    # Get the non-expiring access key (expiration == 1970-01-01T00:00:00Z)
    minio_3_access_key=$(sudo docker exec $container_name mc admin accesskey ls --json $MINIO_ALIAS \
      | grep -B3 '"expiration":"1970-01-01T00:00:00Z"' \
      | grep '"accessKey"' \
      | head -n1 \
      | sed -E 's/.*"accessKey":"([^"]+)".*/\1/')

    # Compare to the S3_SECRET_KEY
    if [[ "$minio_3_access_key" == "$S3_ACCESS_KEY" ]]; then
      echo -e "${GREEN}✅ S3 access key matches S3_ACCESS_KEY in $ENV_FILE${NC}"
    else
      echo -e "${RED}❌ S3 access key does NOT match S3_ACCESS_KEY in $ENV_FILE${NC}"
      echo -e "${YELLOW}MinIO Key: ${minio_3_access_key}${NC}"
      echo -e "${YELLOW}S3_ACCESS_KEY: ${S3_ACCESS_KEY}${NC}"
    fi

    # Verify control-panel has a valid S3_ACCESS_KEY
    if sudo docker logs control-panel 2>&1 | grep -q "InvalidAccessKeyId"; then
      echo -e "${RED}❌ control-panel is reporting InvalidAccessKeyId. You may want to re-run ./minio_init.sh to correct this.${NC}"
    fi


   # sudo docker exec "$container_name" mc ls --summarize --recursive $MINIO_ALIAS
  else
    echo -e "${RED}❌ $container_name is NOT running.${NC}"
  fi

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  container_name="mongo"

  # If mongo exists, display show subdomain details from mongo in the format of https://subdomain.yourdomain.com
  if sudo docker ps --filter "name=$container_name" --filter "status=running" --format "{{.Names}}" | grep -q "^$container_name$"; then
    echo -e "${CYAN}🔄 $container_name is running. Finding any shows in Mongo container '$container_name'...${NC}"

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
      echo -e "${YELLOW}⚠️ No shows have been configured in ${NC}${RED}Remote Falcon${NC}${YELLOW}. Create a new account at:${NC} ${BLUE}🔗 https://$DOMAIN/signup${NC}"
    else
      echo -e "${BLUE}$subdomains${NC}"
    fi
  else
    echo -e "${RED}❌ $container_name is NOT running.${NC}"
  fi

  echo
  echo -e "If everything is running properly, ${RED}Remote Falcon${NC} should be accessible at: ${BLUE}🔗 https://$DOMAIN${NC}"
else
    echo -e "${RED}❌ Error: $ENV_FILE file not found.${NC}"
fi

exit 0