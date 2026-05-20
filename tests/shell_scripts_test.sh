#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="${TMPDIR:-/tmp}/cloudflared-rf-tests.$$"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  echo "not ok - $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  echo "ok - $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  grep -Eq -- "$pattern" "$file" || {
    echo "Expected pattern '$pattern' in $file"
    return 1
  }
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  ! grep -Eq -- "$pattern" "$file" || {
    echo "Unexpected pattern '$pattern' in $file"
    return 1
  }
}

run_test() {
  local name="$1"
  shift

  mkdir -p "$TEST_TMP"
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

make_workspace() {
  local ws
  ws="$(mktemp -d "$TEST_TMP/ws.XXXXXX")"
  mkdir -p "$ws/remotefalcon" "$ws/.github/workflows"

  cp "$ROOT_DIR/configure-rf.sh" "$ws/"
  cp "$ROOT_DIR/run_workflow.sh" "$ws/"
  cp "$ROOT_DIR/setup_cloudflare.sh" "$ws/"
  cp "$ROOT_DIR/shared_functions.sh" "$ws/"
  cp "$ROOT_DIR/sync_repo_secrets.sh" "$ws/"
  cp "$ROOT_DIR/update_containers.sh" "$ws/"
  cp "$ROOT_DIR/versitygw_init.sh" "$ws/"
  cp "$ROOT_DIR/remotefalcon/default.conf" "$ws/remotefalcon/"
  cp "$ROOT_DIR/remotefalcon/compose.yaml" "$ws/remotefalcon/"
  chmod +x "$ws"/*.sh

  cat > "$ws/remotefalcon/.env" <<'ENV'
DOMAIN=example.com
TUNNEL_TOKEN=old-token
REPO=username/repo
GITHUB_PAT=
HOST_ENV=production
DOCKERFILE=Dockerfile
VERSION=2025.1.1
CONTROL_PANEL_API=
VIEWER_API=
VIEWER_JWT_KEY=jwt-key
GOOGLE_MAPS_KEY=maps-key
PUBLIC_POSTHOG_KEY=posthog-key
PUBLIC_POSTHOG_HOST=https://posthog.example.com
GA_TRACKING_ID=GA-TEST
MIXPANEL_KEY=mixpanel
HOSTNAME_PARTS=2
SOCIAL_META=true
SWAP_CP=false
VIEWER_PAGE_SUBDOMAIN=viewer
OTEL_OPTS=
OTEL_URI=
MONGO_INITDB_ROOT_USERNAME=rfuser
MONGO_INITDB_ROOT_PASSWORD=rfpass
MONGO_URI=mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@mongo:27017/remote-falcon?authSource=admin
IMAGES_S3_BUCKET=remote-falcon-images
IMAGES_CDN_ENDPOINT=https://images.example.com
S3_ENDPOINT=http://versitygw:7070
S3_ACCESS_KEY=123456
S3_SECRET_KEY=123456
VERSITYGW_PATH=/home/versitygw-volume
S3_ROOT_USER=12345678
S3_ROOT_PASSWORD=12345678
ENV

  printf '%s\n' "$ws"
}

install_mocks() {
  local ws="$1"
  local bin="$ws/test-bin"
  mkdir -p "$bin"

  cat > "$bin/sudo" <<'MOCK'
#!/usr/bin/env bash
echo "sudo $*" >> "${MOCK_LOG_DIR}/commands.log"
exec "$@"
MOCK

  cat > "$bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

  cat > "$bin/tput" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

  cat > "$bin/envsubst" <<'MOCK'
#!/usr/bin/env bash
input="$(cat)"
eval "printf '%s' \"$input\""
MOCK

  cat > "$bin/openssl" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  rand)
    if [[ "$2" == "-hex" ]]; then
      printf '0123456789abcdef0123456789abcdef\n'
    else
      printf 'base64tunnelsecret\n'
    fi
    ;;
  genrsa)
    printf 'mock private key\n' > "$3"
    ;;
  req)
    out=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-out" ]]; then
        out="$2"
        shift 2
      else
        shift
      fi
    done
    printf 'mock csr\n' > "$out"
    ;;
  *)
    exit 0
    ;;
esac
MOCK

  cat > "$bin/curl" <<'MOCK'
#!/usr/bin/env bash
echo "curl $*" >> "${MOCK_LOG_DIR}/commands.log"
args="$*"

if [[ "$args" == *"/repos/Remote-Falcon/remote-falcon-platform/commits?sha=main&path=apps/external-api"* ]]; then
  printf '[{"sha":"deadbee1234567890abcdef1234567890abcdef1"}]\n'
elif [[ "$args" == *"/repos/Remote-Falcon/remote-falcon-platform/commits/"* ]]; then
  printf '{"sha":"abcdef1234567890abcdef1234567890abcdef12"}\n'
elif [[ "$args" == *"api.cloudflare.com/client/v4/accounts"* && "$args" != *"cfd_tunnel"* ]]; then
  printf '{"success":true,"result":[{"id":"acct-1","name":"Test Account"}]}\n'
elif [[ "$args" == *"/zones?name=example.com"* ]]; then
  printf '{"success":true,"result":[{"id":"zone-1","status":"active"}]}\n'
elif [[ "$args" == *"/dns_records"* && "$args" == *"-X GET"* ]]; then
  printf '{"success":true,"result":[]}\n'
elif [[ "$args" == *"/certificates"* ]]; then
  printf '{"success":true,"result":{"certificate":"mock certificate"}}\n'
elif [[ "$args" == *"/cfd_tunnel?name=rf-example.com"* ]]; then
  printf '{"success":true,"result":[]}\n'
elif [[ "$args" == *"/cfd_tunnel"* && "$args" == *"-X POST"* ]]; then
  printf '{"success":true,"result":{"id":"tunnel-1","token":"new-tunnel-token"}}\n'
elif [[ "$args" == *"external-api"* ]]; then
  printf 'mock release notes\n'
else
  printf '{"success":true,"result":[]}\n'
fi
MOCK

  cat > "$bin/jq" <<'MOCK'
#!/usr/bin/env bash
raw=false
exit_check=false
compact=false
filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r)
      raw=true
      shift
      ;;
    -e)
      exit_check=true
      shift
      ;;
    -c)
      compact=true
      shift
      ;;
    --arg)
      shift 3
      ;;
    *)
      filter="$1"
      shift
      ;;
  esac
done

input="$(cat)"

case "$filter" in
  '.')
    printf '%s\n' "$input"
    ;;
  '.sha // empty')
    echo "$input" | sed -n 's/.*"sha":"\([^"]*\)".*/\1/p'
    ;;
  '.[0].sha')
    echo "$input" | sed -n 's/.*"sha":"\([^"]*\)".*/\1/p' | head -n 1
    ;;
  '.token')
    echo "$input" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
    ;;
  '.name')
    echo "$input" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'
    ;;
  '.status')
    echo "$input" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p'
    ;;
  '.conclusion')
    echo "$input" | sed -n 's/.*"conclusion":"\([^"]*\)".*/\1/p'
    ;;
  '.success'|'.success == true')
    [[ "$input" == *'"success":true'* ]]
    ;;
  '.result | length')
    if [[ "$input" == *'"result":[]'* ]]; then
      echo 0
    elif [[ "$input" == *'"result":['* ]]; then
      echo 1
    else
      echo 0
    fi
    ;;
  '.result[0].id')
    echo "$input" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1
    ;;
  '.result[0].name')
    echo "$input" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -n 1
    ;;
  '.result[0].status')
    echo "$input" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p' | head -n 1
    ;;
  '.result.id')
    echo "$input" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1
    ;;
  '.result.token')
    echo "$input" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -n 1
    ;;
  '.result.certificate')
    echo "$input" | sed -n 's/.*"certificate":"\([^"]*\)".*/\1/p' | head -n 1
    ;;
  '.result.name_servers[]')
    ;;
  '[.result[] | select(.deleted_at == null)] | length // 0')
    echo 0
    ;;
  '[.result[] | select(.deleted_at == null)]')
    echo '[]'
    ;;
  'length // 0')
    if [[ "$input" == "[]" ]]; then echo 0; else echo 1; fi
    ;;
  '.errors[0].code // empty')
    ;;
  *)
    if $exit_check; then
      [[ "$input" == *'"success":true'* ]]
    else
      printf '%s\n' "$input"
    fi
    ;;
esac
MOCK

  cat > "$bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo "gh $*" >> "${MOCK_LOG_DIR}/commands.log"

if [[ "$1 $2" == "auth status" ]]; then
  exit 0
elif [[ "$1 $2" == "api user" ]]; then
  printf 'testuser\n'
elif [[ "$1 $2" == "repo view" ]]; then
  exit 0
elif [[ "$1 $2 $3" == "secret set "* ]]; then
  value="$(cat)"
  echo "secret $3=$value repo=${6:-}" >> "${MOCK_LOG_DIR}/gh-secrets.log"
elif [[ "$1 $2" == "workflow run" ]]; then
  exit 0
elif [[ "$1 $2" == "run list" ]]; then
  printf '12345\n'
elif [[ "$1 $2" == "run view" ]]; then
  args="$*"
  if [[ "$args" == *'select(.status!="completed")'* ]]; then
    printf '0\n'
  elif [[ "$args" == *'select(.conclusion!="success")'* ]]; then
    printf '0\n'
  else
    printf '{"name":"build","status":"completed","conclusion":"success"}\n'
  fi
elif [[ "$1" == "api" ]]; then
  exit 0
fi
MOCK

  cat > "$bin/docker" <<'MOCK'
#!/usr/bin/env bash
echo "docker $*" >> "${MOCK_LOG_DIR}/commands.log"

if [[ "$1" == "compose" && "$*" == *"ps --services"* ]]; then
  printf '%s\n' ${MOCK_RUNNING_SERVICES:-}
elif [[ "$1" == "ps" ]]; then
  printf 'ghcr.io/example/external-api:abc1234\n'
elif [[ "$1" == "exec" && "$*" == *"wget -qO- http://127.0.0.1:7070/health"* ]]; then
  printf 'OK\n'
elif [[ "$1" == "exec" && "$*" == *"list-users"* ]]; then
  printf 'ID AccessKey Role\n-- -------- ---\n'
elif [[ "$1" == "exec" && "$*" == *"list-buckets"* ]]; then
  printf 'Bucket Owner\n------ -----\n'
elif [[ "$1" == "run" && "$*" == *"get-bucket-policy"* ]]; then
  exit 1
elif [[ "$1" == "run" && "$*" == *"put-bucket-policy"* ]]; then
  exit 0
else
  exit 0
fi
MOCK

  chmod +x "$bin"/*
  printf '%s\n' "$bin"
}

with_mocks() {
  local ws="$1"
  local bin
  bin="$(install_mocks "$ws")"
  export MOCK_LOG_DIR="$ws/mock-log"
  export PATH="$bin:$PATH"
  mkdir -p "$MOCK_LOG_DIR"
}

test_bash_syntax() {
  local scripts=(
    configure-rf.sh
    run_workflow.sh
    setup_cloudflare.sh
    shared_functions.sh
    sync_repo_secrets.sh
    update_containers.sh
    versitygw_init.sh
  )

  local script
  for script in "${scripts[@]}"; do
    bash -n "$ROOT_DIR/$script" || return 1
  done
}

test_shared_functions() {
  local ws
  ws="$(make_workspace)"

  (
    cd "$ws" || exit 1
    source ./shared_functions.sh
    parse_env

    [[ "${existing_env_vars[DOMAIN]}" == "example.com" ]] || exit 1
    [[ "${MONGO_URI}" == 'mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@mongo:27017/remote-falcon?authSource=admin' ]] || exit 1

    REPO="owner/repo"
    update_compose_image_path
    grep -Fq 'ghcr.io/${REPO}/external-api:' "$COMPOSE_FILE" || exit 1

    REPO="username/repo"
    update_compose_image_path
    ! grep -Fq 'ghcr.io/${REPO}/external-api:' "$COMPOSE_FILE" || exit 1

    replace_compose_tag external-api 1234567890abcdef1234567890abcdef12345678
    grep -Eq 'external-api:1234567' "$COMPOSE_FILE" || exit 1
    grep -Fq 'github.com/Remote-Falcon/remote-falcon-platform.git#1234567890abcdef1234567890abcdef12345678' "$COMPOSE_FILE" || exit 1
    grep -Fq 'dockerfile: apps/external-api/${DOCKERFILE}' "$COMPOSE_FILE" || exit 1

    replace_compose_tag ui fedcba0987654321fedcba0987654321fedcba09
    grep -Eq 'ui:fedcba0' "$COMPOSE_FILE" || exit 1
    grep -Fq 'github.com/Remote-Falcon/remote-falcon-platform.git#fedcba0987654321fedcba0987654321fedcba09:apps/ui' "$COMPOSE_FILE" || exit 1
    grep -Fq 'dockerfile: ${DOCKERFILE}' "$COMPOSE_FILE" || exit 1

    uname() { printf 'aarch64\n'; }
    is_arm_cpu || exit 1
    uname() { printf 'x86_64\n'; }
    ! is_arm_cpu || exit 1

    memory_check() { return 1; }
    REPO="username/repo"
    GITHUB_PAT=""
    DOCKERFILE="Dockerfile"
    select_dockerfile_for_host
    [[ "$DOCKERFILE" == "Dockerfile.dev" ]] || exit 1

    REPO="owner/repo"
    GITHUB_PAT="ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"
    DOCKERFILE="Dockerfile"
    select_dockerfile_for_host
    [[ "$DOCKERFILE" == "Dockerfile" ]] || exit 1

    check_tag_format external-api 123abcd || exit 1
    ! check_tag_format external-api latest || exit 1
  )
}

test_sync_repo_secrets() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  sed -i 's|^REPO=.*|REPO=test-owner/test-repo|' "$ws/remotefalcon/.env"
  sed -i 's|^GITHUB_PAT=.*|GITHUB_PAT=ghp_test|' "$ws/remotefalcon/.env"

  (
    cd "$ws" || exit 1
    ./sync_repo_secrets.sh
  ) || return 1

  assert_file_contains "$ws/mock-log/gh-secrets.log" '^secret CONTROL_PANEL_API=https://example.com/remote-falcon-control-panel'
  assert_file_contains "$ws/mock-log/gh-secrets.log" '^secret VIEWER_API=https://example.com/remote-falcon-viewer'
  assert_file_contains "$ws/mock-log/gh-secrets.log" '^secret MONGO_URI=mongodb://rfuser:rfpass@mongo:27017/remote-falcon\?authSource=admin'
}

test_run_workflow() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES="versitygw cloudflared"
  sed -i 's|^REPO=.*|REPO=test-owner/test-repo|' "$ws/remotefalcon/.env"
  sed -i 's|^GITHUB_PAT=.*|GITHUB_PAT=ghp_test|' "$ws/remotefalcon/.env"

  (
    cd "$ws" || exit 1
    ./run_workflow.sh external-api=abcdef1
  ) || return 1

  assert_file_contains "$ws/mock-log/commands.log" 'gh workflow run build-container.yml -R test-owner/test-repo -F service=external-api -F ref=abcdef1234567890abcdef1234567890abcdef12'
  assert_file_contains "$ws/mock-log/commands.log" 'docker compose -f .*/remotefalcon/compose.yaml pull'
  assert_file_contains "$ws/mock-log/commands.log" 'docker compose -f .*/remotefalcon/compose.yaml up -d --force-recreate'
}

test_update_containers_dry_run() {
  local ws output
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES=""

  (
    cd "$ws" || exit 1
    ./update_containers.sh external-api dry-run
  ) > "$ws/update.out" 2>&1 || return 1

  output="$(cat "$ws/update.out")"
  [[ "$output" == *"Dry-run:"* ]] || {
    echo "$output"
    return 1
  }
  [[ "$output" == *"external-api"* ]] || return 1
}

test_setup_cloudflare() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES=""

  (
    cd "$ws" || exit 1
    ./setup_cloudflare.sh -y --domain example.com --api-token cf-token
  ) || return 1

  assert_file_contains "$ws/remotefalcon/.env" '^DOMAIN=example.com$'
  assert_file_contains "$ws/remotefalcon/.env" '^TUNNEL_TOKEN=new-tunnel-token$'
  assert_file_contains "$ws/remotefalcon/tunnel_id.txt" '^tunnel-1$'
  assert_file_contains "$ws/remotefalcon/example.com_origin_cert.pem" 'mock certificate'
  assert_file_contains "$ws/remotefalcon/example.com_origin_key.pem" 'mock private key'
}

test_versitygw_init() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES="versitygw"

  (
    cd "$ws" || exit 1
    ./versitygw_init.sh
  ) || return 1

  assert_file_not_contains "$ws/remotefalcon/.env" '^S3_ACCESS_KEY=123456$'
  assert_file_not_contains "$ws/remotefalcon/.env" '^S3_SECRET_KEY=123456$'
  assert_file_not_contains "$ws/remotefalcon/.env" '^S3_ROOT_USER=12345678$'
  assert_file_not_contains "$ws/remotefalcon/.env" '^S3_ROOT_PASSWORD=12345678$'
  assert_file_contains "$ws/mock-log/commands.log" 'create-user'
  assert_file_contains "$ws/mock-log/commands.log" 'create-bucket'
  assert_file_contains "$ws/mock-log/commands.log" 'put-bucket-policy'
}

test_configure_rf_help() {
  local ws
  ws="$(make_workspace)"

  (
    cd "$ws" || exit 1
    ./configure-rf.sh --help
  ) > "$ws/configure-help.out" 2>&1 || return 1

  assert_file_contains "$ws/configure-help.out" '^Usage: .*configure-rf.sh \[options\]'
  assert_file_contains "$ws/configure-help.out" '--non-interactive'
  assert_file_contains "$ws/configure-help.out" '--set KEY=VALUE'
}

run_test "bash syntax for managed scripts" test_bash_syntax
run_test "shared_functions.sh parses env and edits compose safely" test_shared_functions
run_test "sync_repo_secrets.sh syncs transformed build secrets" test_sync_repo_secrets
run_test "run_workflow.sh triggers a mocked single-service build" test_run_workflow
run_test "update_containers.sh supports mocked dry-run checks" test_update_containers_dry_run
run_test "setup_cloudflare.sh completes with mocked Cloudflare API" test_setup_cloudflare
run_test "versitygw_init.sh initializes mocked S3 resources" test_versitygw_init
run_test "configure-rf.sh exposes expected CLI help" test_configure_rf_help

echo
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi
