#!/bin/bash

# VERSION=2026.5.20.1

# Configure new VersityGW container
#set -euo pipefail

CONTAINER_NAME="versitygw"

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/shared_functions.sh" ]]; then
  echo -e "${RED}❌ ERROR: shared_functions.sh does not exist in $SCRIPT_DIR.${NC}"
  exit 1
fi

source "$SCRIPT_DIR/shared_functions.sh"

check_env_exists
parse_env "$ENV_FILE"
LEGACY_MINIO_PATH="${MINIO_PATH:-/home/minio-volume}"

# Ensure required S3 variables are present in the .env file
REQUIRED_S3_VARS=(
  "S3_ENDPOINT=http://versitygw:7070"
  "S3_ACCESS_KEY=123456"
  "S3_SECRET_KEY=123456"
  "IMAGES_S3_BUCKET=remote-falcon-images"
  "VERSITYGW_PATH=/home/versitygw-volume"
  "S3_ROOT_USER=12345678"
  "S3_ROOT_PASSWORD=12345678"
)

for var_def in "${REQUIRED_S3_VARS[@]}"; do
  key="${var_def%%=*}"
  default_val="${var_def#*=}"

  if [[ -z "${existing_env_vars[$key]:-}" ]]; then
    echo -e "➕ Adding missing variable $key with default value '$default_val' to $ENV_FILE"
    echo "$key=$default_val" >> "$ENV_FILE"
    echo "$key"="$default_val"
    existing_env_vars["$key"]="$default_val"
  fi
done

# Builds the bucket policy after credential defaults have been replaced so the
# principal matches the VersityGW user that actually exists.
build_bucket_policy() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::${IMAGES_S3_BUCKET}/*"]
    },
    {
      "Sid": "AppAccessUserOnly",
      "Effect": "Allow",
      "Principal": {
        "AWS": "${S3_ACCESS_KEY}"
      },
      "Action": [
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${IMAGES_S3_BUCKET}",
        "arn:aws:s3:::${IMAGES_S3_BUCKET}/*"
      ]
    }
  ]
}
EOF
}

# Function to check if VersityGW is healthy inside the container by checking the VersityGW health endpoint
check_versitygw_health() {
  max_retries=5
  retry_count=0

  # Wait for VersityGW container to start
  until is_container_running "$CONTAINER_NAME"; do
    ((retry_count++))
    if [[ $retry_count -ge $max_retries ]]; then
      echo -e "${RED}❌ $CONTAINER_NAME did not start after $max_retries attempts. Exiting...${NC}"
      exit 1
    fi
    echo "⏳ Waiting for $CONTAINER_NAME to start (attempt $retry_count/$max_retries)..."
    sleep 2
  done

  # Check if VersityGW is healthy by hitting the health endpoint, no ports are exposed so we use a curl container on the same Docker network to check the health endpoint
  retry_count=0

  while true; do
    status=$(docker exec $CONTAINER_NAME wget -qO- http://127.0.0.1:7070/health 2>/dev/null || true)

    if [[ "$status" == "OK" ]]; then
      break
    fi

    ((retry_count++))

    if [[ $retry_count -ge $max_retries ]]; then
      echo -e "${RED}❌ $CONTAINER_NAME did not become ready after $max_retries attempts.${NC}"
      exit 1
    fi

    echo "⏳ Waiting for $CONTAINER_NAME to be ready (attempt $retry_count/$max_retries)..."
    sleep 2
  done
  echo -e "${GREEN}✅ Container $CONTAINER_NAME is ready.${NC}"
}

echo -e "${BLUE}⚙️ Running Versity Gateway container initialization script to allow for self-hosted Image Hosting under the Control Panel...${NC}"

# If the container is not running start it
if ! is_container_running "$CONTAINER_NAME"; then
  echo -e "${YELLOW}⚠️ $CONTAINER_NAME does not exist or is not running.${NC}"
  echo -e "${BLUE}🔄 Attempting to start $CONTAINER_NAME...${NC}"
  docker compose -f "$COMPOSE_FILE" up -d $CONTAINER_NAME
fi

# Check VersityGW health before proceeding to make sure the container is up and healthy
check_versitygw_health

# Check if S3_ENDPOINT is not set to http://versitygw:7070in the .env and set it if not
if [[ $S3_ENDPOINT != "http://versitygw:7070" ]]; then
  echo -e "${YELLOW}⚠️ S3_ENDPOINT is not set to default value http://versitygw:7070. Writing it to $ENV_FILE...${NC}"
  S3_ENDPOINT="http://versitygw:7070"
  sed -i "s|^S3_ENDPOINT=.*|S3_ENDPOINT=$S3_ENDPOINT|" "$ENV_FILE"

  echo -e "${BLUE}🔄 Restarting container 'control-panel' to use the new S3_ENDPOINT $S3_ENDPOINT...${NC}"
  docker compose -f "$COMPOSE_FILE" rm -f -s control-panel
  docker compose -f "$COMPOSE_FILE" up -d control-panel
else
  echo -e "${GREEN}✅ S3_ENDPOINT is set to recommended default value http://versitygw:7070.${NC}"
fi

# Check S3_ROOT_USER .env variable and generate a random user if set to default 12345678
changed_creds=false
if [[ $S3_ROOT_USER == "12345678" ]]; then
  echo -e "${YELLOW}⚠️ S3_ROOT_USER is set to default value 12345678. Generating a random user and writing it to $ENV_FILE...${NC}"
  S3_ROOT_USER=$(openssl rand -hex 16)
  sed -i "s|^S3_ROOT_USER=.*|S3_ROOT_USER=$S3_ROOT_USER|" "$ENV_FILE"
  changed_creds=true
fi
# Check S3_ROOT_PASSWORD .env variable and generate a random password if set to default 12345678
if [[ $S3_ROOT_PASSWORD == "12345678" ]]; then
  echo -e "${YELLOW}⚠️ S3_ROOT_PASSWORD is set to default value 12345678. Generating a random password and writing it to $ENV_FILE...${NC}"
  S3_ROOT_PASSWORD=$(openssl rand -hex 16)
  sed -i "s|^S3_ROOT_PASSWORD=.*|S3_ROOT_PASSWORD=$S3_ROOT_PASSWORD|" "$ENV_FILE"
  changed_creds=true
fi
# Restart the VersityGW container if the root credentials were changed
if [[ $changed_creds == true ]]; then
  echo -e "${BLUE}🔄 Restarting container '$CONTAINER_NAME' due to changed root credentials...${BLUE}"
  docker compose -f "$COMPOSE_FILE" rm -f -s $CONTAINER_NAME
  docker compose -f "$COMPOSE_FILE" up -d $CONTAINER_NAME
  check_versitygw_health
else
  echo -e "${GREEN}✅ S3_ROOT_USER and S3_ROOT_PASSWORD are set to non-default values.${NC}"
fi

# Check S3_ACCESS_KEY .env variable and generate a random access key if set to default 123456
changed_creds=false
if [[ $S3_ACCESS_KEY == "123456" ]]; then
  echo -e "${YELLOW}⚠️ S3_ACCESS_KEY is set to default value 123456. Generating a random user and writing it to $ENV_FILE...${NC}"
  S3_ACCESS_KEY=$(openssl rand -hex 16)
  sed -i "s|^S3_ACCESS_KEY=.*|S3_ACCESS_KEY=$S3_ACCESS_KEY|" "$ENV_FILE"
  changed_creds=true
fi
# Check S3_SECRET_KEY .env variable and generate a random password if set to default 123456
if [[ $S3_SECRET_KEY == "123456" ]]; then
  echo -e "${YELLOW}⚠️ S3_SECRET_KEY is set to default value 123456. Generating a random password and writing it to $ENV_FILE...${NC}"
  S3_SECRET_KEY=$(openssl rand -hex 16)
  sed -i "s|^S3_SECRET_KEY=.*|S3_SECRET_KEY=$S3_SECRET_KEY|" "$ENV_FILE"
  changed_creds=true
fi
# Restart control panel container if the S3 access key or secret key were changed since those are used by the control panel to access the S3 storage
if [[ $changed_creds == true ]]; then
  echo -e "${BLUE}🔄 Restarting container 'control-panel' to use the new S3 access key and secret key...${BLUE}"
  docker compose -f "$COMPOSE_FILE" rm -f -s control-panel
  docker compose -f "$COMPOSE_FILE" up -d control-panel
else
  echo -e "${GREEN}✅ S3_ACCESS_KEY and S3_SECRET_KEY are already set to non-default values.${NC}"
fi

# Check if a user has been created with the S3_ACCESS_KEY and S3_SECRET_KEY values and if not create a new user with those credentials
if docker exec "$CONTAINER_NAME" versitygw admin -a "$S3_ROOT_USER" -s "$S3_ROOT_PASSWORD" -er http://127.0.0.1:7071 list-users | awk 'NR>2 {print $1}' | grep -qx "$S3_ACCESS_KEY"; then
  echo -e "${GREEN}✅ S3 user '$S3_ACCESS_KEY' already exists.${NC}"
else
  echo "Creating user '$S3_ACCESS_KEY'..."
  docker exec $CONTAINER_NAME versitygw admin -a "$S3_ROOT_USER" -s "$S3_ROOT_PASSWORD" -er http://127.0.0.1:7071 create-user -a "$S3_ACCESS_KEY" -s "$S3_SECRET_KEY" -r user
fi

# Check if the 'remote-falcon-images' bucket already exists else create it
bucket_owner=$(docker exec "$CONTAINER_NAME" versitygw admin -a "$S3_ROOT_USER" -s "$S3_ROOT_PASSWORD" -er http://127.0.0.1:7071 list-buckets | awk -v bucket="$IMAGES_S3_BUCKET" 'NR>2 && $1==bucket {print $2}')
if [[ -n "$bucket_owner" ]]; then
  if [[ "$bucket_owner" == "$S3_ACCESS_KEY" ]]; then
    echo -e "${GREEN}✅ Bucket '$IMAGES_S3_BUCKET' already exists and is owned by '$S3_ACCESS_KEY'.${NC}"
  else
    echo -e "${YELLOW}⚠️ Bucket '$IMAGES_S3_BUCKET' exists but is owned by '$bucket_owner'. Updating owner to'$S3_ACCESS_KEY'.${NC}"
    docker exec "$CONTAINER_NAME" versitygw admin -a "$S3_ROOT_USER" -s "$S3_ROOT_PASSWORD" -er http://127.0.0.1:7071 change-bucket-owner -b "$IMAGES_S3_BUCKET" -o "$S3_ACCESS_KEY"
  fi
else
  echo "🪣 Creating bucket '$IMAGES_S3_BUCKET'..."
  docker exec $CONTAINER_NAME versitygw admin -a "$S3_ROOT_USER" -s "$S3_ROOT_PASSWORD" -er http://127.0.0.1:7071 create-bucket --owner "$S3_ACCESS_KEY" --bucket "$IMAGES_S3_BUCKET"
fi

# Set a bucket policy to allow public access check_bucket_policy is sourced from shared_functions.sh
if check_bucket_policy "$CONTAINER_NAME"; then
  echo -e "${GREEN}✅ Bucket '$IMAGES_S3_BUCKET' policy is already set for public access.${NC}"
else
  echo "🪣 Applying public policy to bucket '$IMAGES_S3_BUCKET'..."
  POLICY=$(build_bucket_policy)
  if ! docker run --rm --network "container:$CONTAINER_NAME" -e AWS_ACCESS_KEY_ID="$S3_ROOT_USER" -e AWS_SECRET_ACCESS_KEY="$S3_ROOT_PASSWORD" amazon/aws-cli --endpoint-url http://$CONTAINER_NAME:7070 s3api put-bucket-policy --bucket "$IMAGES_S3_BUCKET" --policy "$POLICY"; then
    echo -e "${RED}❌ Failed to apply bucket policy for '$IMAGES_S3_BUCKET'.${NC}"
    exit 1
  fi
fi

# Migrate the known legacy Remote Falcon MinIO volume when its old container is
# still available. The source is retained as a dated backup after verification.
migrate_minio_to_versitygw() {
  local minio_container="remote-falcon-images.minio"
  local minio_user minio_password rf_network diff_output backup_path
  local was_running=false network_added=false

  [[ -d "$LEGACY_MINIO_PATH" ]] || return 0
  echo -e "${YELLOW}⚠️ Found legacy Remote Falcon MinIO data at '$LEGACY_MINIO_PATH'.${NC}"

  if ! docker container inspect "$minio_container" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️ The legacy '$minio_container' container was not found. Preserving the MinIO data for manual migration.${NC}"
    return 0
  fi

  minio_user=$(docker inspect "$minio_container" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^MINIO_ROOT_USER=//p' | head -n 1)
  minio_password=$(docker inspect "$minio_container" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^MINIO_ROOT_PASSWORD=//p' | head -n 1)
  if [[ -z "$minio_user" || -z "$minio_password" ]]; then
    echo -e "${RED}❌ Could not recover the legacy MinIO credentials. The source data was not changed.${NC}"
    return 1
  fi

  if [[ "$(docker inspect -f '{{.State.Running}}' "$minio_container")" == "true" ]]; then
    was_running=true
  else
    echo -e "${BLUE}🔄 Starting the stopped legacy MinIO container for migration...${NC}"
    docker start "$minio_container" >/dev/null || return 1
  fi

  rf_network=$(docker inspect "$CONTAINER_NAME" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | head -n 1)
  if [[ -z "$rf_network" ]]; then
    echo -e "${RED}❌ Could not determine the Versity Gateway Docker network. The source data was not changed.${NC}"
    [[ "$was_running" == false ]] && docker stop "$minio_container" >/dev/null
    return 1
  fi
  if ! docker inspect "$minio_container" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | grep -Fxq "$rf_network"; then
    docker network connect "$rf_network" "$minio_container" || return 1
    network_added=true
  fi

  echo -e "${BLUE}🔧 Connecting the migration client to MinIO and Versity Gateway...${NC}"
  if ! docker exec "$minio_container" mc alias set minio http://127.0.0.1:9000 "$minio_user" "$minio_password" >/dev/null ||
     ! docker exec "$minio_container" mc alias set versitygw http://versitygw:7070 "$S3_ROOT_USER" "$S3_ROOT_PASSWORD" >/dev/null; then
    echo -e "${RED}❌ Could not connect to both object stores. The source data was not changed.${NC}"
    [[ "$network_added" == true ]] && docker network disconnect "$rf_network" "$minio_container" >/dev/null 2>&1 || true
    [[ "$was_running" == false ]] && docker stop "$minio_container" >/dev/null
    return 1
  fi

  if ! docker exec "$minio_container" mc ls "minio/$IMAGES_S3_BUCKET" >/dev/null 2>&1; then
    echo -e "${RED}❌ Legacy bucket '$IMAGES_S3_BUCKET' was not found. The source data was not changed.${NC}"
    [[ "$network_added" == true ]] && docker network disconnect "$rf_network" "$minio_container" >/dev/null 2>&1 || true
    [[ "$was_running" == false ]] && docker stop "$minio_container" >/dev/null
    return 1
  fi

  echo -e "${BLUE}📦 Mirroring legacy images to Versity Gateway...${NC}"
  if ! docker exec "$minio_container" mc mirror --overwrite "minio/$IMAGES_S3_BUCKET" "versitygw/$IMAGES_S3_BUCKET"; then
    echo -e "${RED}❌ MinIO migration failed. The source data was not changed.${NC}"
    [[ "$network_added" == true ]] && docker network disconnect "$rf_network" "$minio_container" >/dev/null 2>&1 || true
    [[ "$was_running" == false ]] && docker stop "$minio_container" >/dev/null
    return 1
  fi

  diff_output=$(docker exec "$minio_container" mc --no-color diff "minio/$IMAGES_S3_BUCKET" "versitygw/$IMAGES_S3_BUCKET") || {
    echo -e "${RED}❌ Could not verify the migrated objects. The source data was not changed.${NC}"
    [[ "$network_added" == true ]] && docker network disconnect "$rf_network" "$minio_container" >/dev/null 2>&1 || true
    [[ "$was_running" == false ]] && docker stop "$minio_container" >/dev/null
    return 1
  }
  if [[ -n "$diff_output" ]]; then
    echo "$diff_output"
    echo -e "${RED}❌ Migrated object names or sizes do not match. The source data was not changed.${NC}"
    [[ "$network_added" == true ]] && docker network disconnect "$rf_network" "$minio_container" >/dev/null 2>&1 || true
    [[ "$was_running" == false ]] && docker stop "$minio_container" >/dev/null
    return 1
  fi

  echo -e "${GREEN}✅ MinIO objects match Versity Gateway by path and size.${NC}"
  docker stop "$minio_container" >/dev/null || return 1
  backup_path="${LEGACY_MINIO_PATH}.migrated-$(date +%Y%m%d-%H%M%S)"
  if mv "$LEGACY_MINIO_PATH" "$backup_path" 2>/dev/null || sudo -n mv "$LEGACY_MINIO_PATH" "$backup_path" 2>/dev/null; then
    echo -e "${GREEN}✅ Preserved the legacy MinIO volume at '$backup_path'.${NC}"
  else
    echo -e "${YELLOW}⚠️ Migration succeeded, but the legacy volume could not be renamed. It remains at '$LEGACY_MINIO_PATH'.${NC}"
  fi
  echo -e "${BLUE}🔄 Restarting nginx to apply the Versity Gateway configuration...${NC}"
  docker compose -f "$COMPOSE_FILE" restart nginx
  echo -e "${GREEN}✅ Migration to Versity Gateway complete.${NC}"
}

migrate_minio_to_versitygw || exit 1

echo "🚀 Done! Exiting versitygw_init script..."
exit 0
