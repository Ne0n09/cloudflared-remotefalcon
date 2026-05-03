#!/bin/bash

# VERSION=2026.5.3.2

# Configure new VersityGW container
#set -euo pipefail

CONTAINER_NAME="versitygw"
MINIO_PATH="/home/minio-volume"

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

# Defines a variable for the the bucket policy we want to apply to the images bucket to allow public read access to the objects in the bucket.
POLICY=$(cat <<EOF
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
)

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
    status=$(sudo docker exec $CONTAINER_NAME wget -qO- http://127.0.0.1:7070/health 2>/dev/null || true)

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
  echo -e "${GREEN}✅ Conttainer $CONTAINER_NAME is ready.${NC}"
}

echo -e "${BLUE}⚙️ Running Versity Gateway container initialization script to allow for self-hosted Image Hosting under the Control Panel...${NC}"

# If the container is not running start it
if ! is_container_running "$CONTAINER_NAME"; then
  echo -e "${YELLOW}⚠️ $CONTAINER_NAME does not exist or is not running.${NC}"
  echo -e "${BLUE}🔄 Attempting to start $CONTAINER_NAME...${NC}"
  sudo docker compose -f "$COMPOSE_FILE" up -d $CONTAINER_NAME
fi

# Check VersityGW health before proceeding to make sure the container is up and healthy
check_versitygw_health

# Check if S3_ENDPOINT is not set to http://versitygw:7070in the .env and set it if not
if [[ $S3_ENDPOINT != "http://versitygw:7070" ]]; then
  echo -e "${YELLOW}⚠️ S3_ENDPOINT is not set to default value http://versitygw:7070. Writing it to $ENV_FILE...${NC}"
  S3_ENDPOINT="http://versitygw:7070"
  sed -i "s|^S3_ENDPOINT=.*|S3_ENDPOINT=$S3_ENDPOINT|" "$ENV_FILE"

  echo -e "${BLUE}🔄 Restarting container 'control-panel' to use the new S3_ENDPOINT $S3_ENDPOINT...${NC}"
  sudo docker compose -f "$COMPOSE_FILE" rm -f -s control-panel
  sudo docker compose -f "$COMPOSE_FILE" up -d control-panel
else
  echo -e "${GREEN}✅ S3_ENDPOINT is set to recommended default value http://versitygw:7070.${NC}"
fi

# Check S3_ROOT_USER .env variable and generate a random user if set to default 12345678
changed_creds=false
if [[ $S3_ROOT_USER == "12345678" ]]; then
  echo -e "${YELLOW}⚠️ S3_ROOT_USER is set to default value 12345678. Generating a random user and writing it to $ENV_FILE...${NC}"
  S3_ROOT_USER=$(openssl rand -hex 16)
  sed -i "s|^S3_ROOT_USER=.*|S3_ROOT_USER=$S3_ROOT_USER|" "$ENV_FILE"
  changes_creds=true
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
  sudo docker compose -f "$COMPOSE_FILE" rm -f -s $CONTAINER_NAME
  sudo docker compose -f "$COMPOSE_FILE" up -d $CONTAINER_NAME
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
  changes_creds=true
fi
# Check S3_SECRET_KEY .env variable and generate a random password if set to default 123456
if [[ $S3_SECRET_KEY == "123456" ]]; then
  echo -e "${YELLOW}⚠️ S3_ROOT_PASSWORD is set to default value 123456. Generating a random password and writing it to $ENV_FILE...${NC}"
  S3_SECRET_KEY=$(openssl rand -hex 16)
  sed -i "s|^S3_SECRET_KEY=.*|S3_SECRET_KEY=$S3_SECRET_KEY|" "$ENV_FILE"
  changed_creds=true
fi
# Restart control panel container if the S3 access key or secret key were changed since those are used by the control panel to access the S3 storage
if [[ $changed_creds == true ]]; then
  echo -e "${BLUE}🔄 Restarting container 'control-panel' to use the new S3 access key and secret key...${BLUE}"
  sudo docker compose -f "$COMPOSE_FILE" rm -f -s control-panel
  sudo docker compose -f "$COMPOSE_FILE" up -d control-panel
else
  echo -e "${GREEN}✅ S3_ACCESS_KEY and S3_SECRET_KEY are already set to non-default values.${NC}"
fi

# Check if a user has been created with the S3_ACCESS_KEY and S3_SECRET_KEY values and if not create a new user with those credentials
if sudo docker exec $CONTAINER_NAME versitygw admin -a $S3_ROOT_USER -s $S3_ROOT_PASSWORD -er http://127.0.0.1:7071 list-users | awk 'NR>2 {print $1}' | grep -qx "$S3_ACCESS_KEY"; then
  echo -e "${GREEN}✅ S3 user '$S3_ACCESS_KEY' already exists.${NC}"
else
  echo "Creating user '$S3_ACCESS_KEY'..."
  sudo docker exec $CONTAINER_NAME versitygw admin -a $S3_ROOT_USER -s $S3_ROOT_PASSWORD -er http://127.0.0.1:7071 create-user -a $S3_ACCESS_KEY -s $S3_SECRET_KEY -r user
fi

# Check if the 'remote-falcon-images' bucket already exists else create it
bucket_owner=$(sudo docker exec "$CONTAINER_NAME" versitygw admin -a "$S3_ROOT_USER" -s "$S3_ROOT_PASSWORD" -er http://127.0.0.1:7071 list-buckets | awk -v bucket="$IMAGES_S3_BUCKET" 'NR>2 && $1==bucket {print $2}')
if [[ -n "$bucket_owner" ]]; then
  if [[ "$bucket_owner" == "$S3_ACCESS_KEY" ]]; then
    echo -e "${GREEN}✅ Bucket '$IMAGES_S3_BUCKET' already exists and is owned by '$S3_ACCESS_KEY'.${NC}"
  else
    echo -e "${YELLOW}⚠️ Bucket '$IMAGES_S3_BUCKET' exists but is owned by '$bucket_owner'. Updating owner to'$S3_ACCESS_KEY'.${NC}"
    sudo docker exec "$CONTAINER_NAME" versitygw admin -a "$S3_ROOT_USER" -s "$S3_ROOT_PASSWORD" -er http://127.0.0.1:7071 change-bucket-owner -b $IMAGES_S3_BUCKET -o $S3_ACCESS_KEY
  fi
else
  echo "🪣 Creating bucket '$IMAGES_S3_BUCKET'..."
  sudo docker exec $CONTAINER_NAME versitygw admin -a $S3_ROOT_USER -s $S3_ROOT_PASSWORD -er http://127.0.0.1:7071 create-bucket --owner $S3_ACCESS_KEY --bucket $IMAGES_S3_BUCKET
fi

# Set a bucket policy to allow public access check_bucket_policy is sourced from shared_functions.sh
if check_bucket_policy "$CONTAINER_NAME"; then
  echo -e "${GREEN}✅ Bucket '$IMAGES_S3_BUCKET' policy is already set for public access.${NC}"
else
  echo "🪣 Applying public policy to bucket '$IMAGES_S3_BUCKET'..."
  sudo docker run --rm --network "container:$CONTAINER_NAME" -e AWS_ACCESS_KEY_ID="$S3_ROOT_USER" -e AWS_SECRET_ACCESS_KEY="$S3_ROOT_PASSWORD" amazon/aws-cli --endpoint-url http://$CONTAINER_NAME:7070 s3api put-bucket-policy --bucket "$IMAGES_S3_BUCKET" --policy "$POLICY"
fi

# Check for existing MinIO installation and migrate from MinIO to VersityGW
migrate_minio_to_versitygw() {

  # Function to check for MinIO readiness
  check_minio_health() {
    echo -e "${BLUE}⏳ Waiting for MinIO container to become ready...${NC}"
    max_retries=5
    retry_count=0

    # Wait for MinIO container to start
    until [[ "$(sudo docker inspect -f '{{.State.Running}}' "$MINIO_CONTAINER" 2>/dev/null)" == "true" ]]; do
      ((retry_count++))
      if [[ $retry_count -ge $max_retries ]]; then
        echo -e "${RED}❌ $MINIO_CONTAINER did not start after $max_retries attempts. Exiting...${NC}"
        exit 1
      fi
      echo "⏳ Waiting for $MINIO_CONTAINER to start (attempt $retry_count/$max_retries)..."
      sleep 2
    done

    # Check if MinIO is healthy inside the container
    retry_count=0

    until [[ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9000/minio/health/ready)" == "200" ]]; do
      ((retry_count++))
      if [[ $retry_count -ge $max_retries ]]; then
        echo -e "${RED}❌ MinIO did not become ready after $max_retries attempts. Exiting...${NC}"
        [[ "$TEMP_MINIO" == true ]] && sudo docker rm -f "$MINIO_CONTAINER"
        exit 1
      fi
      echo "⏳ Waiting for MinIO to be ready inside container '$MINIO_CONTAINER'..."
      sleep 2
    done

    # Add a small sleep to ensure MinIO is fully ready, otherwise mc alias set will fail
    sleep 2
    echo -e "${GREEN}✅ MinIO is ready.${NC}"
  }

  # Function to check bucket exists and print object count and total size
  check_bucket_exists() {
    local container="$1"
    local alias="$2"
    local bucket="$3"

    echo "🔍 Checking bucket '$bucket' and object information for alias '$alias'..."

    local output
    output=$(sudo docker exec "$container" mc du --recursive "$alias" 2>/dev/null || true)

    echo "$output"

    if echo "$output" | awk '{print $NF}' | grep -Fxq "$bucket"; then
      echo -e "${GREEN}✅ Bucket '$bucket' found for alias '$alias'.${NC}"
    else
      echo -e "${RED}❌ Bucket '$bucket' not found for alias '$alias'.${NC}"
      return 1
    fi
  }

  # Check if MINIO_PATH is set in .env and if it is set to a path that exists on the host machine, if so we assume the user has an existing MinIO installation and we want to migrate that data to the VersityGW S3 storage
  if [[ -d "$MINIO_PATH" ]]; then
    echo -e "${YELLOW}⚠️ MINIO_PATH is set to '$MINIO_PATH' and the directory exists. Assuming existing MinIO installation...${NC}"
    echo -e "${BLUE}🔄 Attempting to migrate existing MinIO data to Versity Gateway storage...${NC}"
    echo -e "${YELLOW}⚠️ Checking for existing MinIO container...${NC}"

    RF_NETWORK=$(get_container_network "versitygw")
    MINIO_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep -E 'minio' | head -n 1)
    TEMP_MINIO=false

    if [[ -n "$MINIO_CONTAINER" ]]; then
      echo -e "${GREEN}✅ Found running MinIO container: $MINIO_CONTAINER${NC}"
      # Capture existing MINIO_ROOT_USER and MINIO_ROOT_PASSWORD from the running container's environment variables as these get removed from the updated .env
      MINIO_ROOT_USER=$(sudo docker inspect remote-falcon-images.minio \
      --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "MINIO_ROOT_USER"}}{{index (split . "=") 1}}{{end}}{{end}}')

      MINIO_ROOT_PASSWORD=$(sudo docker inspect remote-falcon-images.minio \
      --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "MINIO_ROOT_PASSWORD"}}{{index (split . "=") 1}}{{end}}{{end}}')

    else
      echo -e "${RED}❌ No running MinIO container found. Data will not be migrated${NC}"
      return 1

      MINIO_CONTAINER="minio"
      TEMP_MINIO=true

      # Start a temporary MinIO container with the existing data directory mounted
      # sudo docker run -d --name "$MINIO_CONTAINER" --network "$RF_NETWORK" -v "$MINIO_PATH:/data" -p 9000:9000 -p 9001:9001 -e MINIO_ROOT_USER="$MINIO_ROOT_USER" -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" coollabsio/minio:latest server /data --address ":9000" >/dev/null
    fi

    check_minio_health

    # Configure mc alias for MinIO and VersityGW
    echo -e "${BLUE}🔧 Configuring mc alias for minio...${NC}"
    sudo docker exec $MINIO_CONTAINER mc alias set minio http://minio:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
    echo -e "${BLUE}🔧 Configuring mc alias for versitygw...${NC}"
    sudo docker exec $MINIO_CONTAINER mc alias set versitygw http://versitygw:7070 $S3_ROOT_USER $S3_ROOT_PASSWORD
    echo -e "${GREEN}✅ Aliases configured.${NC}"

    # List contents of source and destination buckets for verification
    check_bucket_exists "$MINIO_CONTAINER" "minio" "$IMAGES_S3_BUCKET" || exit 1
    check_bucket_exists "$MINIO_CONTAINER" "versitygw" "$IMAGES_S3_BUCKET" || exit 1

    # Check if source and destination bucket object count match
    src_count=$(sudo docker exec "$MINIO_CONTAINER" mc ls minio/$IMAGES_S3_BUCKET --recursive | wc -l)
    dst_count=$(sudo docker exec "$MINIO_CONTAINER" mc ls versitygw/$IMAGES_S3_BUCKET --recursive | wc -l)

    if [[ "$src_count" -eq "$dst_count" ]]; then
      echo -e "${GREEN}✅ No migration needed. Buckets are in sync.${NC}"
      echo -e "${BLUE}🧹 Removing MinIO directory...${NC}"
      sudo rm -rf "$MINIO_PATH"
    else
      echo -e "${YELLOW}⚠️ Buckets are not in sync. Migration needed.${NC}"
      # Display dry-run migration and request confirmation before proceeding
#      echo -e "${CYAN}🔍 Dry-run migration preview...${NC}"
#      sudo docker exec $MINIO_CONTAINER mc mirror --dry-run minio/$IMAGES_S3_BUCKET versitygw/$IMAGES_S3_BUCKET

#      read -p "Proceed with migration? (y/n): " confirm
#      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
#        echo -e "${YELLOW}⚠️ Migration cancelled.${NC}"
#        [[ "$TEMP_MINIO" == true ]] && sudo docker rm -f "$MINIO_CONTAINER"
#        return
#      else
        # Perform the migration
        echo -e "${BLUE}📦 Migrating data from MinIO to Versity Gateway...${NC}"
        sudo docker exec $MINIO_CONTAINER mc mirror --overwrite minio/$IMAGES_S3_BUCKET versitygw/$IMAGES_S3_BUCKET

        # Verify the migration completed by comparing object counts
        echo -e "${BLUE}🔍 Verifying migration...${NC}"
        src_count=$(sudo docker exec $MINIO_CONTAINER mc ls minio/$IMAGES_S3_BUCKET --recursive | wc -l)
        dst_count=$(sudo docker exec $MINIO_CONTAINER mc ls versitygw/$IMAGES_S3_BUCKET --recursive | wc -l)

        echo -e "📊 MinIO objects:      $src_count"
        echo -e "📊 VersityGW objects: $dst_count"

        if [[ "$src_count" == "$dst_count" ]]; then
          echo -e "${GREEN}✅ Migration verified successfully.${NC}"
          echo -e "${BLUE}🧹 Removing MinIO directory...${NC}"
          sudo rm -rf "$MINIO_PATH"
        else
          echo -e "${RED}❌ Object count mismatch!${NC}"
        fi
      #fi
    fi

    # Stop MinIO container
    echo -e "${BLUE}🧹 Removing MinIO container...${NC}"
    sudo docker rm -f "$MINIO_CONTAINER" >/dev/null
    # Restart nginx to ensure old MinIO proxy configuration is removed
    echo -e "${BLUE}🔄 Restarting nginx to apply new default.conf...${NC}"
    sudo docker compose -f "$COMPOSE_FILE" restart nginx

    echo -e "${GREEN}✅ Migration to Versity Gateway complete.${NC}"
  fi
}

migrate_minio_to_versitygw


echo "🚀 Done! Exiting versitygw_init script..."
exit 0

# Need to check for already running minio container when compose.yaml is updated
