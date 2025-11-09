#!/bin/bash

# VERSION=2025.11.8.1

#set -euo pipefail

CONTAINER_NAME="remote-falcon-images.minio"

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/shared_functions.sh" ]]; then
  echo -e "${RED}❌ ERROR: shared_functions.sh does not exist in $SCRIPT_DIR.${NC}"
  exit 1
fi

source "$SCRIPT_DIR/shared_functions.sh"

check_env_exists
parse_env "$ENV_FILE"

# Ensure required S3 variables are present in the .env file
REQUIRED_S3_VARS=(
  "MINIO_PATH=/home/minio-volume"
  "MINIO_ROOT_USER=12345678"
  "MINIO_ROOT_PASSWORD=12345678"
  "S3_ENDPOINT=http://minio:9000"
  "S3_ACCESS_KEY=123456"
  "S3_SECRET_KEY=123456"
)

for var_def in "${REQUIRED_S3_VARS[@]}"; do
  key="${var_def%%=*}"
  default_val="${var_def#*=}"

  if [[ -z "${existing_env_vars[$key]:-}" ]]; then
    echo -e "➕ Adding missing variable $key with default value '$default_val' to $ENV_FILE"
    echo "$key=$default_val" >> "$ENV_FILE"
    "$key"="$default_val"
    existing_env_vars["$key"]="$default_val"
  fi
done

# Use docker inspect to check if the container is running by passing container name as an argument
container_running() {
  local container_name="$1"
  local running
  running=$(sudo docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null) || return 1
  [[ "$running" == "true" ]]
}

# Function to check if MinIO is healthy inside the container by checking the MinIO health endpoint
check_minio_health() {
  max_retries=5
  retry_count=0

  # Wait for MinIO container to start
  until container_running "$CONTAINER_NAME"; do
    ((retry_count++))
    if [[ $retry_count -ge $max_retries ]]; then
      echo -e "${RED}❌ $CONTAINER_NAME did not start after $max_retries attempts. Exiting...${NC}"
      exit 1
    fi
    echo "⏳ Waiting for $CONTAINER_NAME to start (attempt $retry_count/$max_retries)..."
    sleep 2
  done

  # Check if MinIO is healthy inside the container
  retry_count=0

  until curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9000/minio/health/ready || true; do
    ((retry_count++))
    if [[ $retry_count -ge $max_retries ]]; then
      echo -e "${RED}❌ MinIO did not become ready after $max_retries attempts. Exiting...${NC}"
      exit 1
    fi
    echo "⏳ Waiting for MinIO to be ready inside container '$CONTAINER_NAME'..."
    sleep 2
  done

  # Add a small sleep to ensure MinIO is fully ready, otherwise mc alias set will fail
  sleep 2
  echo -e "${GREEN}✅ MinIO is ready.${NC}"
}

echo -e "${BLUE}⚙️ Running MinIO container initialization script to allow for self-hosted Image Hosting under the Control Panel...${NC}"

# If the container is not running start it
if ! container_running "$CONTAINER_NAME"; then
  echo -e "${YELLOW}⚠️ $CONTAINER_NAME does not exist or is not running.${NC}"
  echo -e "${BLUE}🔄 Attempting to start $CONTAINER_NAME...${NC}"
  sudo docker compose -f "$COMPOSE_FILE" up -d minio
fi

# Check MinIO health before proceeding to make sure the container is up and healthy
check_minio_health

# Check if S3_ENDPOINT is not set to http://minio:9000 in the .env and set it if not
if [[ $S3_ENDPOINT != "http://minio:9000" ]]; then
  echo -e "${YELLOW}⚠️ S3_ENDPOINT is not set to default value http://minio:9000. Writing it to $ENV_FILE...${NC}"
  S3_ENDPOINT="http://minio:9000"
  sed -i "s|^S3_ENDPOINT=.*|S3_ENDPOINT=$S3_ENDPOINT|" "$ENV_FILE"

  echo -e "${BLUE}🔄 Restarting container 'control-panel' to use the new S3_ENDPOINT $S3_ENDPOINT...${NC}"
  sudo docker compose -f "$COMPOSE_FILE" rm -f -s control-panel
  sudo docker compose -f "$COMPOSE_FILE" up -d control-panel
else
  echo -e "${GREEN}✅ S3_ENDPOINT is set to recommended default value http://minio:9000.${NC}"
fi

# Check MINIO_ROOT_USER .env variable and generate a random user if set to default 12345678
changed_creds=false
if [[ $MINIO_ROOT_USER == "12345678" ]]; then
  echo -e "${YELLOW}⚠️ MINIO_ROOT_USER is set to default value 12345678. Generating a random user and writing it to $ENV_FILE...${NC}"
  MINIO_ROOT_USER=$(openssl rand -hex 16)
  sed -i "s|^MINIO_ROOT_USER=.*|MINIO_ROOT_USER=$MINIO_ROOT_USER|" "$ENV_FILE"
  changes_creds=true
fi
# Check MINIO_ROOT_PASSWORD .env variable and generate a random password if set to default 12345678
if [[ $MINIO_ROOT_PASSWORD == "12345678" ]]; then
  echo -e "${YELLOW}⚠️ MINIO_ROOT_PASSWORD is set to default value 12345678. Generating a random password and writing it to $ENV_FILE...${NC}"
  MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)
  sed -i "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD|" "$ENV_FILE"
  changed_creds=true
fi
# Restart the minio container if the root credentials were changed
## Change these all to docker compose commands?
if [[ $changed_creds == true ]]; then
  echo -e "${BLUE}🔄 Restarting container '$CONTAINER_NAME' due to changed root credentials...${BLUE}"
  sudo docker compose -f "$COMPOSE_FILE" rm -f -s minio
  sudo docker compose -f "$COMPOSE_FILE" up -d minio
  check_minio_health
else
  echo -e "${GREEN}✅ MINIO_ROOT_USER and MINIO_ROOT_PASSWORD are set to non-default values.${NC}"
fi

# Configure mc alias to connect to the MinIO server to check/create bucket and check/create access key
ALIAS_CMD="mc alias set $MINIO_ALIAS $S3_ENDPOINT $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD"

max_retries=5
retry_count=0
alias_success=false

while [[ $retry_count -lt $max_retries ]]; do
  output=$(sudo docker exec "$CONTAINER_NAME" $ALIAS_CMD 2>&1) && alias_success=true && break

  echo "$output"

  if echo "$output" | grep -qiE "connection refused|Access Key Id you provided does not exist"; then
    echo -e "${YELLOW}⚠️ Detected transient MinIO startup issue during 'mc alias set' command. Waiting and retrying (attempt $((retry_count + 1))/$max_retries)...${NC}"
    ((retry_count++))
    sleep 3
  else
    echo -e "${RED}❌ Unexpected error while running 'mc alias set' command. Exiting...${NC}"
    exit 1
  fi
done

if [[ "$alias_success" == false ]]; then
  echo -e "${RED}❌ Failed to set mc alias after $max_retries attempts. Exiting...${NC}"
  exit 1
else
  echo -e "${GREEN}✅ MinIO 'mc alias set' completed successfully.${NC}"
fi

# Check if the 'remote-falcon-images' bucket already exists else create it
if sudo docker exec "$CONTAINER_NAME" mc ls "$MINIO_ALIAS" | grep -q "$BUCKET_NAME/"; then
  echo -e "${GREEN}✅ Bucket '$BUCKET_NAME' already exists.${NC}"
else
  echo "🪣 Creating bucket '$BUCKET_NAME'..."
  sudo docker exec "$CONTAINER_NAME" mc mb "$MINIO_ALIAS/$BUCKET_NAME"
fi

# Make bucket public
if sudo docker exec "$CONTAINER_NAME" mc anonymous get "$MINIO_ALIAS/$BUCKET_NAME" | grep -q "Access permission.*is.*public"; then
  echo -e "${GREEN}✅ Bucket '$BUCKET_NAME' is already public.${NC}"
else
  echo "🪣 Making bucket '$BUCKET_NAME' public..."
  sudo docker exec "$CONTAINER_NAME" mc anonymous set public "$MINIO_ALIAS/$BUCKET_NAME"
fi

# Create access key/secret key if set to the default 123456 and capture output
if [[ $S3_ACCESS_KEY == "123456" || $S3_SECRET_KEY == "123456" ]]; then
  echo -e "${YELLOW}⚠️ S3_ACCESS_KEY or S3_SECRET_KEY is set to default value 123456. Generating a random S3 access key and secret key...${NC}"
  access_output=$(sudo docker exec "$CONTAINER_NAME" mc admin accesskey create --json $MINIO_ALIAS --name $ACCESS_KEY_NAME)

  # Parse accessKey and secretKey from the JSON output
  access_key=$(echo "$access_output" | grep -o '"accessKey":[^,]*' | cut -d':' -f2 | tr -d ' "')
  secret_key=$(echo "$access_output" | grep -o '"secretKey":[^,}]*' | cut -d':' -f2 | tr -d ' "')

  if [[ -z "$access_key" || -z "$secret_key" ]]; then
    echo -e "${RED}❌ Failed to parse S3 access or secret key.${NC}"
    exit 1
  fi

  # Update .env file with the new access key and secret key
  sed -i "s|^S3_ACCESS_KEY=.*|S3_ACCESS_KEY=$access_key|" "$ENV_FILE"
  sed -i "s|^S3_SECRET_KEY=.*|S3_SECRET_KEY=$secret_key|" "$ENV_FILE"

  echo -e "${GREEN}✅ New S3 access key and secret key written to $ENV_FILE${NC}"
  echo -e "${BLUE}🔄 Restarting container 'control-panel' to use the new S3 access key and secret key...${NC}"
  sudo docker compose -f "$COMPOSE_FILE" rm -f -s control-panel
  sudo docker compose -f "$COMPOSE_FILE" up -d control-panel
else
  echo -e "${GREEN}✅ S3_ACCESS_KEY and S3_SECRET_KEY are already set to non-default values.${NC}"
fi

echo "🚀 Done! Exiting minio-init script..."
exit 0