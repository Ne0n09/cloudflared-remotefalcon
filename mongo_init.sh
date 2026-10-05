#!/usr/bin/env bash

# VERSION=2026.9.29.5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared_functions.sh
source "$SCRIPT_DIR/shared_functions.sh"

MONGO_CONTAINER="mongo"
MONGO_DATABASE="remote-falcon"
DEFAULT_ROOT_USERNAME="root"
DEFAULT_ROOT_PASSWORD="root"
DEFAULT_APP_USERNAME="remotefalcon"
DEFAULT_APP_PASSWORD="change-me"
ROOT_ROTATION_MARKER="$WORKING_DIR/.mongo-root-rotation-pending"
APPLICATION_SERVICES=(plugins-api control-panel viewer external-api)

check_compose_exists
check_env_exists
parse_env
MONGO_NO_AVX_PIN_ACTIVE=false
prepare_mongo_cpu_compatibility

set_env_value() {
  local key="$1" value="$2" temporary
  temporary=$(mktemp "${ENV_FILE}.XXXXXX")
  awk -v target="$key" -v replacement="$value" '
    BEGIN { updated=0 }
    index($0, target "=")==1 { print target "=" replacement; updated=1; next }
    { print }
    END { if (!updated) print target "=" replacement }
  ' "$ENV_FILE" > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$ENV_FILE"
}

generate_secret() {
  openssl rand -hex 32
}

mongo_root_ready() {
  local username="$1" password="$2"
  docker exec "$MONGO_CONTAINER" mongosh \
    --quiet \
    --username "$username" \
    --password "$password" \
    --authenticationDatabase admin \
    --eval "db.adminCommand({ ping: 1 }).ok" >/dev/null 2>&1
}

wait_for_mongo_root() {
  local username="$1" password="$2" attempt
  for attempt in $(seq 1 30); do
    if mongo_root_ready "$username" "$password"; then
      return 0
    fi
    sleep 2
  done
  echo -e "${RED}❌ MongoDB did not accept the configured root credentials.${NC}" >&2
  return 1
}

fresh_mongo_storage() {
  if docker container inspect "$MONGO_CONTAINER" >/dev/null 2>&1; then
    return 1
  fi
  if [[ -d "${MONGO_PATH:-}" ]] && find "$MONGO_PATH" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    return 1
  fi
  return 0
}

write_root_rotation_marker() {
  local username="$1" password="$2"
  (umask 077; printf 'MONGO_INITDB_ROOT_USERNAME=%s\nMONGO_INITDB_ROOT_PASSWORD=%s\n' \
    "$username" "$password" > "$ROOT_ROTATION_MARKER")
}

read_marker_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$ROOT_ROTATION_MARKER" | head -n 1
}

recover_interrupted_root_rotation() {
  local pending_username pending_password attempt
  [[ -f "$ROOT_ROTATION_MARKER" ]] || return 0
  chmod 600 "$ROOT_ROTATION_MARKER"
  pending_username=$(read_marker_value MONGO_INITDB_ROOT_USERNAME)
  pending_password=$(read_marker_value MONGO_INITDB_ROOT_PASSWORD)
  if [[ -z "$pending_username" || -z "$pending_password" ]]; then
    echo -e "${RED}❌ Invalid MongoDB root-rotation recovery marker: $ROOT_ROTATION_MARKER${NC}" >&2
    return 1
  fi

  for attempt in $(seq 1 30); do
    if mongo_root_ready "$pending_username" "$pending_password"; then
      echo -e "${YELLOW}⚠️ Completing an interrupted MongoDB root credential update.${NC}"
      set_env_value MONGO_INITDB_ROOT_USERNAME "$pending_username"
      set_env_value MONGO_INITDB_ROOT_PASSWORD "$pending_password"
      rm -f "$ROOT_ROTATION_MARKER"
      parse_env
      rf_compose up -d --force-recreate --no-deps "$MONGO_CONTAINER"
      wait_for_mongo_root "$pending_username" "$pending_password"
      return 0
    fi

    if mongo_root_ready "$MONGO_INITDB_ROOT_USERNAME" "$MONGO_INITDB_ROOT_PASSWORD"; then
      echo -e "${YELLOW}⚠️ The prior MongoDB root rotation did not reach the database; retrying safely.${NC}"
      rm -f "$ROOT_ROTATION_MARKER"
      return 0
    fi
    sleep 2
  done

  echo -e "${RED}❌ Neither the configured nor pending MongoDB root credentials are valid.${NC}" >&2
  echo "Restore the matching .env backup or repair the MongoDB root user before retrying." >&2
  return 1
}

ensure_application_user() {
  docker exec \
    -e RF_MONGO_APP_USERNAME="$MONGO_APP_USERNAME" \
    -e RF_MONGO_APP_PASSWORD="$MONGO_APP_PASSWORD" \
    -e RF_MONGO_DATABASE="$MONGO_DATABASE" \
    "$MONGO_CONTAINER" mongosh \
      --quiet \
      --username "$MONGO_INITDB_ROOT_USERNAME" \
      --password "$MONGO_INITDB_ROOT_PASSWORD" \
      --authenticationDatabase admin \
      --eval '
        const appDb = db.getSiblingDB(process.env.RF_MONGO_DATABASE);
        const username = process.env.RF_MONGO_APP_USERNAME;
        const specification = {
          pwd: process.env.RF_MONGO_APP_PASSWORD,
          roles: [{ role: "readWrite", db: process.env.RF_MONGO_DATABASE }]
        };
        if (appDb.getUser(username)) appDb.updateUser(username, specification);
        else appDb.createUser({ user: username, ...specification });
      ' >/dev/null
}

verify_application_user() {
  docker exec "$MONGO_CONTAINER" mongosh \
    --quiet \
    --username "$MONGO_APP_USERNAME" \
    --password "$MONGO_APP_PASSWORD" \
    --authenticationDatabase "$MONGO_DATABASE" \
    --eval "db.getSiblingDB('$MONGO_DATABASE').runCommand({ connectionStatus: 1 }).ok" |
    grep -q 1
}

recreate_running_applications() {
  local service
  local -a running=()
  for service in "${APPLICATION_SERVICES[@]}"; do
    if grep -Fxq "$service" <<< "$RUNNING_SERVICES_BEFORE"; then
      running+=("$service")
    fi
  done
  if (( ${#running[@]} > 0 )); then
    echo -e "${BLUE}🔄 Recreating running application containers with the dedicated MongoDB user...${NC}"
    rf_compose up -d --force-recreate --no-deps "${running[@]}"
  fi
}

rotate_default_root_password() {
  local new_password="$1"
  write_root_rotation_marker "$MONGO_INITDB_ROOT_USERNAME" "$new_password"
  docker exec \
    -e RF_MONGO_ROOT_USERNAME="$MONGO_INITDB_ROOT_USERNAME" \
    -e RF_MONGO_NEW_ROOT_PASSWORD="$new_password" \
    "$MONGO_CONTAINER" mongosh \
      --quiet \
      --username "$MONGO_INITDB_ROOT_USERNAME" \
      --password "$MONGO_INITDB_ROOT_PASSWORD" \
      --authenticationDatabase admin \
      --eval '
        db.getSiblingDB("admin").updateUser(
          process.env.RF_MONGO_ROOT_USERNAME,
          { pwd: process.env.RF_MONGO_NEW_ROOT_PASSWORD }
        );
      ' >/dev/null

  set_env_value MONGO_INITDB_ROOT_PASSWORD "$new_password"
  rm -f "$ROOT_ROTATION_MARKER"
  parse_env
  rf_compose up -d --force-recreate --no-deps "$MONGO_CONTAINER"
  wait_for_mongo_root "$MONGO_INITDB_ROOT_USERNAME" "$MONGO_INITDB_ROOT_PASSWORD"
}

root_username_missing=false
app_username_missing=false
[[ -z "${MONGO_INITDB_ROOT_USERNAME:-}" ]] && root_username_missing=true
[[ -z "${MONGO_APP_USERNAME:-}" ]] && app_username_missing=true
MONGO_INITDB_ROOT_USERNAME="${MONGO_INITDB_ROOT_USERNAME:-$DEFAULT_ROOT_USERNAME}"
MONGO_INITDB_ROOT_PASSWORD="${MONGO_INITDB_ROOT_PASSWORD:-$DEFAULT_ROOT_PASSWORD}"
MONGO_APP_USERNAME="${MONGO_APP_USERNAME:-$DEFAULT_APP_USERNAME}"
MONGO_APP_PASSWORD="${MONGO_APP_PASSWORD:-}"
RUNNING_SERVICES_BEFORE="$(rf_compose ps --services --filter status=running 2>/dev/null || true)"

root_password_is_default=false
app_password_is_default=false
[[ "$MONGO_INITDB_ROOT_PASSWORD" == "$DEFAULT_ROOT_PASSWORD" ]] && root_password_is_default=true
[[ -z "$MONGO_APP_PASSWORD" || "$MONGO_APP_PASSWORD" == "$DEFAULT_APP_PASSWORD" ]] && app_password_is_default=true

if [[ "$root_password_is_default" == true || "$app_password_is_default" == true ]] ||
   ! grep -q '^MONGO_APP_USERNAME=' "$ENV_FILE" ||
   ! grep -q '^MONGO_URI=mongodb://${MONGO_APP_USERNAME}:${MONGO_APP_PASSWORD}@mongo:27017/remote-falcon?authSource=remote-falcon$' "$ENV_FILE"; then
  backup_file "$ENV_FILE"
fi

if fresh_mongo_storage; then
  echo -e "${CYAN}🔐 Preparing random MongoDB credentials before first startup...${NC}"
  [[ "$root_password_is_default" == true ]] && MONGO_INITDB_ROOT_PASSWORD="$(generate_secret)"
  [[ "$app_password_is_default" == true ]] && MONGO_APP_PASSWORD="$(generate_secret)"
  [[ "$root_username_missing" == true ]] && set_env_value MONGO_INITDB_ROOT_USERNAME "$MONGO_INITDB_ROOT_USERNAME"
  [[ "$root_password_is_default" == true ]] && set_env_value MONGO_INITDB_ROOT_PASSWORD "$MONGO_INITDB_ROOT_PASSWORD"
  [[ "$app_username_missing" == true ]] && set_env_value MONGO_APP_USERNAME "$MONGO_APP_USERNAME"
  [[ "$app_password_is_default" == true ]] && set_env_value MONGO_APP_PASSWORD "$MONGO_APP_PASSWORD"
  set_env_value MONGO_URI 'mongodb://${MONGO_APP_USERNAME}:${MONGO_APP_PASSWORD}@mongo:27017/remote-falcon?authSource=remote-falcon'
  parse_env
  rf_compose up -d "$MONGO_CONTAINER"
  wait_for_mongo_root "$MONGO_INITDB_ROOT_USERNAME" "$MONGO_INITDB_ROOT_PASSWORD"
else
  rf_compose up -d "$MONGO_CONTAINER"
  if [[ -f "$ROOT_ROTATION_MARKER" ]]; then
    recover_interrupted_root_rotation
  else
    wait_for_mongo_root "$MONGO_INITDB_ROOT_USERNAME" "$MONGO_INITDB_ROOT_PASSWORD"
  fi
  [[ "$app_password_is_default" == true ]] && MONGO_APP_PASSWORD="$(generate_secret)"
  [[ "$app_username_missing" == true ]] && set_env_value MONGO_APP_USERNAME "$MONGO_APP_USERNAME"
  [[ "$app_password_is_default" == true ]] && set_env_value MONGO_APP_PASSWORD "$MONGO_APP_PASSWORD"
  set_env_value MONGO_URI 'mongodb://${MONGO_APP_USERNAME}:${MONGO_APP_PASSWORD}@mongo:27017/remote-falcon?authSource=remote-falcon'
  parse_env
fi

ensure_application_user
if ! verify_application_user; then
  echo -e "${RED}❌ The dedicated MongoDB application user could not authenticate.${NC}" >&2
  exit 1
fi
echo -e "${GREEN}✔ Dedicated MongoDB application user is configured with database-scoped read/write access.${NC}"

recreate_running_applications

if [[ "$root_password_is_default" == true && "$MONGO_INITDB_ROOT_PASSWORD" == "$DEFAULT_ROOT_PASSWORD" ]]; then
  echo -e "${YELLOW}⚠️ MongoDB root password is still the default. Rotating it now...${NC}"
  rotate_default_root_password "$(generate_secret)"
else
  echo -e "${GREEN}✔ MongoDB root password is non-default.${NC}"
fi

echo -e "${GREEN}✔ MongoDB credential initialization completed.${NC}"
