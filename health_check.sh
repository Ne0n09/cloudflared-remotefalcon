#!/bin/bash

# VERSION=2026.5.3.2

#set -euo pipefail
#set -x

SERVICES=(external-api ui plugins-api viewer control-panel cloudflared nginx mongo versitygw)
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
Register tunnel error from server side error|Verify that the tunnel exists and token is correct.
'

CONTAINER_PATTERNS["nginx"]='
Error response from daemon: No such container|Container is not running
connect() failed (111: Connection refused) while connecting to upstream|NGINX cannot connect to RF containers. Try restarting NGINX container or all containers.
'

CONTAINER_PATTERNS["mongo"]='
Error response from daemon: No such container|Container is not running
requires a CPU with AVX support|Check that your CPU supports AVX, if running in VM try changing VM CPU to 'host' type.
'

CONTAINER_PATTERNS["versitygw"]='
Error response from daemon: No such container|Container is not running
'

CONTAINER_PATTERNS["external-api"]='
Error response from daemon: No such container|Container is not running
'

CONTAINER_PATTERNS["plugins-api"]='
Error response from daemon: No such container|Container is not running
state=CONNECTING, exception={com.mongodb.MongoSocketOpenException: Exception opening socket}, caused by {java.net.ConnectException: Connection refused|Verify that your MONGO_URI is correct and rebuild image.
'

CONTAINER_PATTERNS["viewer"]='
Error response from daemon: No such container|Container is not running
state=CONNECTING, exception={com.mongodb.MongoSocketOpenException: Exception opening socket}, caused by {java.net.ConnectException: Connection refused|Verify that your MONGO_URI is correct and rebuild image.
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

check_endpoint() {
  # Perform the request and capture both code and DNS errors
  response_file="/tmp/curl_response"
  http_code_file="/tmp/http_code"
  error_log="/tmp/curl_error.log"

  # Ensure cleanup before each check
  rm -f "$response_file" "$http_code_file"

  curl -sS -o "$response_file" -w "%{http_code}" "$endpoint" > "$http_code_file" 2>"$error_log"
  http_code=$(cat "$http_code_file" 2>/dev/null || echo "000")
  health_status=$(jq -r '.status // "UNKNOWN"' "$response_file" 2>/dev/null)
}

  # Iterate through each container and its endpoint if it is running
  for rf_container in "${!rf_containers[@]}"; do
    endpoint="${rf_containers[$rf_container]}"

    if ! is_container_running "$rf_container"; then
      echo -e "${RED}❌ $rf_container is NOT running.${NC}"
      HEALTHY=false
      continue
    else
      attempt=1
      while true; do
        check_endpoint

        # Check if the status is "UP" or handle errors
        if [[ "$http_code" -eq 200 ]]; then
          if [[ "$health_status" == "UP" ]]; then
            echo -e "  ${YELLOW}•${NC} ${GREEN}✅ $rf_container endpoint ${BLUE}🔗 $endpoint${NC} ${GREEN}status is UP${NC}"
            break  # Success, exit retry loop
          fi
        else
          if [[ $attempt -lt $MAX_RETRIES ]]; then
            echo -e "${YELLOW}⚠️ $rf_container endpoint status check attempt ($attempt/$MAX_RETRIES) failed. Retrying in $RETRY_DELAY seconds...${NC}"
            sleep $RETRY_DELAY
            ((attempt++))
          else
            # Final failure after retries
            if [[ "$http_code" -ne 200 ]]; then
              # Detect DNS resolution or network errors
              if grep -qiE "Could not resolve host|Name or service not known|Temporary failure in name resolution" "$error_log"; then
                echo -e "${RED}🌐 Unable to resolve host for $rf_container endpoint. Check that your DNS records are configured correctly. If so you may have to wait for records to propagate.${NC}"
              fi
              echo -e "  ${YELLOW}•${NC} ${RED}❌ $rf_container HTTP Error: $http_code (Endpoint ${BLUE}🔗 $endpoint${NC} ${RED}may be down)${NC}"
              HEALTHY=false
            else
              echo -e "  ${YELLOW}•${NC} ${RED}❌ $rf_container endpoint ${BLUE}🔗 $endpoint${NC} ${RED}status is NOT UP (Current status: $status)${NC}"
              echo -e "${YELLOW}⚠️ Check the logs with 'sudo docker logs $rf_container' for more information.${NC}"
            fi
            break  # Give up after max retries
          fi
        fi
      done
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
      ON_DISK_CERT_KEY_MATCH=true
    else
      echo -e "${RED}❌ The certificate and private key do NOT match:${NC}"
      HEALTHY=false
      ON_DISK_CERT_KEY_MATCH=false
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
  
    if echo "$nginx_test_output" | grep -q "syntax is ok" && echo "$nginx_test_output" | grep -q "test is successful"; then
      echo -e "${GREEN}✅ NGINX configuration test successful.${NC}"
    else
      echo "$nginx_test_output"
      if echo "$nginx_test_output" | grep -q "key values mismatch" && $ON_DISK_CERT_KEY_MATCH == true; then
        echo -e "${YELLOW}⚠️ Detected certificate/key mismatch inside the NGINX container, but the on disk certificate and key match.${NC}"
        echo -e "${YELLOW}🔁 Attempting to restart $container_name to correct the issue... ${NC}"
        sudo docker restart $container_name
        echo "💤 Sleeping 5s before re-testing $container_name..."
        sleep 5s
        # Re-test NGINX configuration
        echo -e "${CYAN}🔄 Re-testing $container_name configuration after restart...${NC}"
        nginx_test_output_post=$(sudo docker exec $container_name nginx -t 2>&1)

        if echo "$nginx_test_output_post" | grep -q "syntax is ok" && echo "$nginx_test_output_post" | grep -q "test is successful"; then
          echo -e "${GREEN}✅ NGINX configuration test successful after restart.${NC}"
        else
          echo "$nginx_test_output_post"
          echo -e "${RED}❌ NGINX configuration test still failing after restart. Check certficates, certificate paths, and default.conf.${NC}"
          HEALTHY=false
        fi
      else
        echo -e "${RED}❌ NGINX configuration test FAILED. Check default.conf${NC}"
      fi
    fi
  else
    echo -e "${RED}❌ $container_name is NOT running.${NC}"
    HEALTHY=false
  fi

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  container_name="versitygw"

  # Check if the VersityGW container is running
  if is_container_running $container_name; then
    echo -e "${CYAN}🔄 $container_name is running. Checking the status of the VersityGW server...${NC}"
 
    output=$(sudo docker exec "$container_name" wget -qO- http://127.0.0.1:7070/health 2>/dev/null || true)

    if [[ "$output" == "OK" ]]; then
      echo -e "${GREEN}✅ $container_name is ready.${NC}"
    fi

    # Check if bucket exists
    echo "🔍 Checking if bucket '$IMAGES_S3_BUCKET' exists..."
    bucket_owner=$(sudo docker exec "$container_name" versitygw admin -a "$S3_ROOT_USER" -s "$S3_ROOT_PASSWORD" -er http://127.0.0.1:7071 list-buckets | awk -v bucket="$IMAGES_S3_BUCKET" 'NR>2 && $1==bucket {print $2}')
    if [[ -n "$bucket_owner" ]]; then
      if [[ "$bucket_owner" == "$S3_ACCESS_KEY" ]]; then
        echo -e "${GREEN}✅ Bucket '$IMAGES_S3_BUCKET' exists and is owned by '$S3_ACCESS_KEY'.${NC}"
      else
        echo -e "${YELLOW}⚠️ Bucket '$IMAGES_S3_BUCKET' exists but is owned by '$bucket_owner'. Re-run ./versitygw_init.sh${NC}"
      fi

      # Check bucket policy for public access
      if check_bucket_policy "$container_name"; then
        echo -e "${GREEN}✅ Bucket '$IMAGES_S3_BUCKET' policy is already set for public access.${NC}"
      else
        echo -e "${RED}❌ Bucket '$IMAGES_S3_BUCKET' policy is not set for public access. Re-run ./versitygw_init.sh${NC}"
      fi
    else
      echo -e "${RED}❌ Bucket '$IMAGES_S3_BUCKET' not found in $container_name. Re-run ./versitygw_init.sh${NC}"
    fi

    # Print bucket and object information
    echo "🔍 Checking bucket '$IMAGES_S3_BUCKET' object information..."
    #sudo docker run --rm --network "container:$container_name" -e AWS_ACCESS_KEY_ID="$S3_ROOT_USER" -e AWS_SECRET_ACCESS_KEY="$S3_ROOT_PASSWORD" amazon/aws-cli --endpoint-url http://$container_name:7070 s3 ls s3://$IMAGES_S3_BUCKET --summarize --recursive --human-readable
    sudo docker run --rm --network "container:$container_name" -e AWS_ACCESS_KEY_ID="$S3_ROOT_USER" -e AWS_SECRET_ACCESS_KEY="$S3_ROOT_PASSWORD" amazon/aws-cli --endpoint-url "http://127.0.0.1:7070" s3 ls "s3://$IMAGES_S3_BUCKET" --recursive \
    | awk '
    {
      size=$3
      key=$4

      split(key, parts, "/")
      prefix=parts[1]

      count[prefix]++
      bytes[prefix]+=size
    }
    END {
      for (p in bytes) {
        printf "%8.1f MiB  %5d objects      %s/%s\n",
          bytes[p]/1024/1024,
          count[p],
          "'$IMAGES_S3_BUCKET'",
          p
      }
    }
    '

    # Verify control-panel has a valid S3_ACCESS_KEY
    if sudo docker logs control-panel 2>&1 | grep -q "InvalidAccessKeyId"; then
      echo -e "${RED}❌ control-panel is reporting InvalidAccessKeyId. You may want to re-run ./versitygw_init.sh to correct this.${NC}"
    fi

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
      if [[ $SWAP_CP == true ]]; then
        echo -e "${YELLOW}⚠️ No shows have been configured in ${NC}${RED}Remote Falcon${NC}${YELLOW}. Create a new account at:${NC} ${BLUE}🔗 https://controlpanel.$DOMAIN/signup${NC}"
      else
        echo -e "${YELLOW}⚠️ No shows have been configured in ${NC}${RED}Remote Falcon${NC}${YELLOW}. Create a new account at:${NC} ${BLUE}🔗 https://$DOMAIN/signup${NC}"
      fi
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