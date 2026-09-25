#!/usr/bin/env bash

# VERSION=2026.9.25.1

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RF_DEPLOY_CHECK_ATTEMPTS=1
export RF_DEPLOY_CHECK_DELAY=0
export HEALTH_MAX_RETRIES=3
export HEALTH_RETRY_DELAY=0
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
  local output
  local status
  output="$("$@" 2>&1)"
  status=$?
  if [[ $status -eq 0 ]]; then
    pass "$name"
  else
    [[ -n "$output" ]] && printf '%s\n' "$output"
    fail "$name"
  fi
}

make_workspace() {
  local ws
  ws="$(mktemp -d "$TEST_TMP/ws.XXXXXX")"
  mkdir -p "$ws/remotefalcon" "$ws/.github/workflows"

  cp "$ROOT_DIR/configure-rf.sh" "$ws/"
  cp "$ROOT_DIR/health_check.sh" "$ws/"
  cp "$ROOT_DIR/install.sh" "$ws/"
  cp "$ROOT_DIR/run_workflow.sh" "$ws/"
  cp "$ROOT_DIR/setup_cloudflare.sh" "$ws/"
  cp "$ROOT_DIR/shared_functions.sh" "$ws/"
  cp "$ROOT_DIR/sync_repo_secrets.sh" "$ws/"
  cp "$ROOT_DIR/update_containers.sh" "$ws/"
  cp "$ROOT_DIR/update_scripts.sh" "$ws/"
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
NGINX_CERT=example.com_origin_cert.pem
NGINX_KEY=example.com_origin_key.pem
CLIENT_HEADER=client-ip
ENV

  printf 'mock certificate\n' > "$ws/remotefalcon/example.com_origin_cert.pem"
  printf 'mock private key\n' > "$ws/remotefalcon/example.com_origin_key.pem"

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
  x509|rsa)
    printf 'mock public key\n'
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

if [[ "$args" == *"-w %{http_code}"* ]]; then
  out=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-o" ]]; then
      out="$2"
      shift 2
    else
      shift
    fi
  done
  [[ -n "$out" ]] && printf '{"status":"UP"}\n' > "$out"
  printf '%s' "${MOCK_HTTP_CODE:-200}"
elif [[ "$args" == *"/repos/Remote-Falcon/remote-falcon-platform/commits/6a96bdf"* ]]; then
  printf '{"sha":"6a96bdf111111111111111111111111111111111"}\n'
elif [[ "$args" == *"/repos/Remote-Falcon/remote-falcon-platform/commits/f781ef4"* ]]; then
  printf '{"sha":"f781ef4222222222222222222222222222222222"}\n'
elif [[ "$args" == *"/repos/Remote-Falcon/remote-falcon-platform/commits/1537f5e"* ]]; then
  printf '{"sha":"1537f5e333333333333333333333333333333333"}\n'
elif [[ "$args" == *"/repos/Remote-Falcon/remote-falcon-platform/commits/40c5cdf"* ]]; then
  printf '{"sha":"40c5cdf444444444444444444444444444444444"}\n'
elif [[ "$args" == *"/repos/Remote-Falcon/remote-falcon-platform/commits/d451653"* ]]; then
  printf '{"sha":"d451653555555555555555555555555555555555"}\n'
elif [[ "$args" == *"/repos/Remote-Falcon/remote-falcon-platform/commits?sha=main&path=apps/external-api"* ]]; then
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
input_file=""

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
      if [[ -n "$filter" && -f "$1" ]]; then
        input_file="$1"
      else
        filter="$1"
      fi
      shift
      ;;
  esac
done

if [[ -n "$input_file" ]]; then
  input="$(cat "$input_file")"
else
  input="$(cat)"
fi

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
  '.status // "UNKNOWN"')
    echo "$input" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p'
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

if [[ "${MOCK_COMPOSE_CONFIG_FAIL:-}" == "true" && "$1" == "compose" && "$*" == *" config -q"* ]]; then
  exit 1
elif [[ "${MOCK_LEGACY_MINIO:-}" == "true" && "$1 $2" == "container inspect" ]]; then
  exit 0
elif [[ "${MOCK_LEGACY_MINIO:-}" == "true" && "$1" == "inspect" && "$*" == *".Config.Env"* ]]; then
  printf 'MINIO_ROOT_USER=legacy-user\nMINIO_ROOT_PASSWORD=legacy-password\n'
elif [[ "${MOCK_LEGACY_MINIO:-}" == "true" && "$1" == "inspect" && "$*" == *".State.Running"* ]]; then
  printf 'false\n'
elif [[ "${MOCK_LEGACY_MINIO:-}" == "true" && "$1" == "inspect" && "$*" == *".NetworkSettings.Networks"* && "$*" == *"versitygw"* ]]; then
  printf 'rf-network\n'
elif [[ "${MOCK_LEGACY_MINIO:-}" == "true" && "$1" == "inspect" && "$*" == *".NetworkSettings.Networks"* ]]; then
  printf 'legacy-network\n'
elif [[ "$1" == "compose" && "$*" == *"ps --services"* ]]; then
  printf '%s\n' ${MOCK_RUNNING_SERVICES:-}
elif [[ "$1" == "inspect" && "$*" == *"{{.Image}}"* ]]; then
  printf '%s\n' "${MOCK_OLD_IMAGE_ID:-}"
elif [[ "$1" == "inspect" && "$*" == *"{{.Config.Image}}"* ]]; then
  printf '%s\n' "${MOCK_OLD_IMAGE_REF:-}"
elif [[ "$1" == "ps" ]]; then
  printf 'ghcr.io/example/external-api:abc1234\n'
elif [[ "$1" == "logs" ]]; then
  exit 0
elif [[ "$1" == "exec" && "$2" == "nginx" && "$*" == *"nginx -t"* ]]; then
  printf 'nginx: the configuration file /etc/nginx/nginx.conf syntax is ok\n'
  printf 'nginx: configuration file /etc/nginx/nginx.conf test is successful\n'
elif [[ "$1" == "exec" && "$*" == *"wget -qO- http://127.0.0.1:7070/health"* ]]; then
  printf 'OK\n'
elif [[ "$1" == "exec" && "$*" == *"list-users"* ]]; then
  printf 'ID AccessKey Role\n-- -------- ---\n'
elif [[ "$1" == "exec" && "$*" == *"list-buckets"* ]]; then
  if [[ "${MOCK_BUCKET_EXISTS:-}" == "true" ]]; then
    printf 'Bucket Owner\n------ -----\nremote-falcon-images 123456\n'
  else
    printf 'Bucket Owner\n------ -----\n'
  fi
elif [[ "$1" == "exec" && "$2" == "mongo" && "$*" == *"mongosh"* ]]; then
  printf 'No subdomains found\n'
elif [[ "$1" == "run" && "$*" == *"get-bucket-policy"* ]]; then
  if [[ "${MOCK_BUCKET_POLICY_EXISTS:-}" == "true" ]]; then
    printf '%s\n' '{"Policy":"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"PublicRead\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":[\"s3:GetObject\"],\"Resource\":[\"arn:aws:s3:::remote-falcon-images/*\"]},{\"Sid\":\"AppAccessUserOnly\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"123456\"},\"Action\":[\"s3:PutObject\",\"s3:DeleteObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::remote-falcon-images\",\"arn:aws:s3:::remote-falcon-images/*\"]}]}"}'
    exit 0
  else
    exit 1
  fi
elif [[ "$1" == "run" && "$*" == *"put-bucket-policy"* ]]; then
  exit 0
elif [[ "$1" == "run" && "$*" == *"s3 ls"* ]]; then
  printf '%s' "${MOCK_S3_LS_OUTPUT:-}"
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
    health_check.sh
    install.sh
    run_workflow.sh
    setup_cloudflare.sh
    shared_functions.sh
    sync_repo_secrets.sh
    update_containers.sh
    update_scripts.sh
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
    grep -Fq "# 'ui' will always use Dockerfile and never Dockerfile.dev" "$COMPOSE_FILE" || exit 1

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

test_get_current_version() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"

  (
    cd "$ws" || exit 1
    source ./shared_functions.sh
    [[ "$(get_current_version external-api)" == "abc1234" ]]
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
  export MOCK_RUNNING_SERVICES="external-api ui plugins-api viewer control-panel cloudflared nginx mongo versitygw"
  sed -i 's|^REPO=.*|REPO=test-owner/test-repo|' "$ws/remotefalcon/.env"
  sed -i 's|^GITHUB_PAT=.*|GITHUB_PAT=ghp_test|' "$ws/remotefalcon/.env"

  (
    cd "$ws" || exit 1
    ./run_workflow.sh external-api=abcdef1
  ) || return 1

  assert_file_contains "$ws/mock-log/commands.log" 'gh workflow run build.yml -R test-owner/test-repo -F service=external-api -F ref=abcdef1234567890abcdef1234567890abcdef12'
  assert_file_contains "$ws/remotefalcon/compose.yaml" 'external-api:abcdef1'
  assert_file_contains "$ws/mock-log/commands.log" 'docker compose -f .*/remotefalcon/compose.yaml pull external-api'
  assert_file_contains "$ws/mock-log/commands.log" 'docker compose -f .*/remotefalcon/compose.yaml up -d --no-deps --force-recreate external-api'
  assert_file_not_contains "$ws/mock-log/commands.log" 'force-recreate.*mongo'
}

test_run_workflow_multi_service_pinned() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES="external-api ui plugins-api viewer control-panel cloudflared nginx mongo versitygw"
  sed -i 's|^REPO=.*|REPO=test-owner/test-repo|' "$ws/remotefalcon/.env"
  sed -i 's|^GITHUB_PAT=.*|GITHUB_PAT=ghp_test|' "$ws/remotefalcon/.env"

  (
    cd "$ws" || exit 1
    ./run_workflow.sh external-api=6a96bdf ui=f781ef4 control-panel=1537f5e plugins-api=40c5cdf viewer=d451653
  ) || return 1

  assert_file_contains "$ws/mock-log/commands.log" 'gh workflow run build.yml -R test-owner/test-repo -F service=all -F ref=main'
  assert_file_contains "$ws/mock-log/commands.log" '-F external-api=6a96bdf111111111111111111111111111111111'
  assert_file_contains "$ws/mock-log/commands.log" '-F ui=f781ef4222222222222222222222222222222222'
  assert_file_contains "$ws/mock-log/commands.log" '-F control-panel=1537f5e333333333333333333333333333333333'
  assert_file_contains "$ws/mock-log/commands.log" '-F plugins-api=40c5cdf444444444444444444444444444444444'
  assert_file_contains "$ws/mock-log/commands.log" '-F viewer=d451653555555555555555555555555555555555'

  assert_file_contains "$ws/remotefalcon/compose.yaml" 'external-api:6a96bdf'
  assert_file_contains "$ws/remotefalcon/compose.yaml" 'ui:f781ef4'
  assert_file_contains "$ws/remotefalcon/compose.yaml" 'control-panel:1537f5e'
  assert_file_contains "$ws/remotefalcon/compose.yaml" 'plugins-api:40c5cdf'
  assert_file_contains "$ws/remotefalcon/compose.yaml" 'viewer:d451653'
}

test_run_workflow_no_args() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES="external-api ui plugins-api viewer control-panel cloudflared nginx mongo versitygw"
  sed -i 's|^REPO=.*|REPO=test-owner/test-repo|' "$ws/remotefalcon/.env"
  sed -i 's|^GITHUB_PAT=.*|GITHUB_PAT=ghp_test|' "$ws/remotefalcon/.env"

  (
    cd "$ws" || exit 1
    ./run_workflow.sh
  ) > "$ws/run-workflow.out" 2>&1 || return 1

  assert_file_contains "$ws/mock-log/commands.log" 'gh workflow run build.yml -R test-owner/test-repo -F service=all -F ref=main'
  assert_file_not_contains "$ws/run-workflow.out" 'Updating compose.yaml tags for explicitly requested commits'
}

test_run_workflow_invalid_argument() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES="versitygw cloudflared"
  sed -i 's|^REPO=.*|REPO=test-owner/test-repo|' "$ws/remotefalcon/.env"
  sed -i 's|^GITHUB_PAT=.*|GITHUB_PAT=ghp_test|' "$ws/remotefalcon/.env"

  (
    cd "$ws" || exit 1
    ./run_workflow.sh bad-service=abcdef1
  ) > "$ws/run-workflow-invalid.out" 2>&1 && return 1

  assert_file_contains "$ws/run-workflow-invalid.out" 'Invalid argument: bad-service=abcdef1'
  assert_file_not_contains "$ws/mock-log/commands.log" 'gh workflow run'
}

test_run_workflow_rolls_back_failed_deploy() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES="mongo nginx cloudflared versitygw"
  export MOCK_OLD_IMAGE_ID="sha256:oldimage"
  export MOCK_OLD_IMAGE_REF="ghcr.io/test-owner/test-repo/external-api:oldtag"
  sed -i 's|^REPO=.*|REPO=test-owner/test-repo|' "$ws/remotefalcon/.env"
  sed -i 's|^GITHUB_PAT=.*|GITHUB_PAT=ghp_test|' "$ws/remotefalcon/.env"
  cp "$ws/remotefalcon/compose.yaml" "$ws/previous-compose.yaml"

  if (cd "$ws" && ./run_workflow.sh external-api=abcdef1) > "$ws/failed-deploy.out" 2>&1; then
    echo "Expected failed deployment to return nonzero"
    return 1
  fi
  cmp "$ws/previous-compose.yaml" "$ws/remotefalcon/compose.yaml" || return 1
  assert_file_contains "$ws/mock-log/commands.log" 'docker image tag rf-rollback-external-api:.* ghcr.io/test-owner/test-repo/external-api:oldtag'
  assert_file_contains "$ws/failed-deploy.out" 'Restoring prior Compose file and images'
}

test_print_env_redacts_secrets() {
  local ws
  ws="$(make_workspace)"
  (
    source "$ws/shared_functions.sh"
    parse_env "$ws/remotefalcon/.env"
    print_env
  ) > "$ws/printed-env.out" || return 1
  assert_file_contains "$ws/printed-env.out" 'TUNNEL_TOKEN.*\[redacted\]'
  assert_file_not_contains "$ws/printed-env.out" 'old-token'
}

test_health_check_missing_env_fails() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  rm "$ws/remotefalcon/.env"
  if (cd "$ws" && ./health_check.sh 0s) > "$ws/health-missing.out" 2>&1; then
    echo "Expected missing .env to return nonzero"
    return 1
  fi
}

test_targeted_health_check() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES="plugins-api"
  (cd "$ws" && ./health_check.sh 0s plugins-api) > "$ws/target.out" 2>&1 || return 1
  assert_file_contains "$ws/target.out" 'plugins-api health checks passed' || return 1
  assert_file_not_contains "$ws/mock-log/commands.log" 'docker (logs.* (mongo|viewer|control-panel)|exec|run)' || return 1
  if (cd "$ws" && ./health_check.sh 0s nonexistent) > /dev/null 2>&1; then return 1; fi
  export MOCK_RUNNING_SERVICES=""
  if (cd "$ws" && ./health_check.sh 0s plugins-api) > /dev/null 2>&1; then return 1; fi
}

test_quarkus_environment_migration() {
  local ws
  ws="$(make_workspace)"
  sed -i '/QUARKUS_MONGODB_CONNECTION_STRING=/d' "$ws/remotefalcon/compose.yaml"
  sed -i 's|^      - MONGO_URI=.*|      - MONGO_URI=${MONGO_URI}|' "$ws/remotefalcon/compose.yaml"
  (
    source "$ws/shared_functions.sh"
    ensure_quarkus_mongo_environment plugins-api || exit 1
    cp "$COMPOSE_FILE" "$ws/once.yaml"
    ensure_quarkus_mongo_environment plugins-api || exit 1
    cmp "$COMPOSE_FILE" "$ws/once.yaml" || exit 1
    [[ $(grep -c 'QUARKUS_MONGODB_CONNECTION_STRING=' "$COMPOSE_FILE") == 1 ]] || exit 1
    assert_file_contains "$COMPOSE_FILE" 'QUARKUS_MONGODB_CONNECTION_STRING=mongodb://\$\{MONGO_INITDB_ROOT_USERNAME\}' || exit 1
    sed -i 's|^MONGO_URI=.*|MONGO_URI=mongodb://custom-db:27018/custom|' "$ENV_FILE"
    ensure_quarkus_mongo_environment viewer || exit 1
    assert_file_contains "$COMPOSE_FILE" 'QUARKUS_MONGODB_CONNECTION_STRING=mongodb://custom-db:27018/custom'
  )
}

test_control_panel_environment_migration() {
  local ws
  ws="$(make_workspace)"
  sed -i '/- DOMAIN=${DOMAIN}/d; s|- IMAGES_CDN_ENDPOINT=.*|- IMAGES_CDN_ENDPOINT=${IMAGES_CDN_ENDPOINT}|' "$ws/remotefalcon/compose.yaml"
  (
    source "$ws/shared_functions.sh"
    ensure_service_runtime_environment control-panel || exit 1
    cp "$COMPOSE_FILE" "$ws/once.yaml"
    ensure_service_runtime_environment control-panel || exit 1
    cmp "$COMPOSE_FILE" "$ws/once.yaml" || exit 1
    [[ $(grep -c -- '- DOMAIN=${DOMAIN}' "$COMPOSE_FILE") == 1 ]] || exit 1
    [[ $(grep -c -- '- IMAGES_CDN_ENDPOINT=https://${DOMAIN}/${IMAGES_S3_BUCKET}' "$COMPOSE_FILE") == 1 ]]
  )
}

test_update_targeted_health_and_rollback() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES="plugins-api"
  export MOCK_OLD_IMAGE_ID="sha256:oldimage"
  export MOCK_OLD_IMAGE_REF="plugins-api:oldtag"
  sed '/^# ========== Main update logic ==========/,$d' "$ws/update_containers.sh" > "$ws/update-functions.sh"
  (
    source "$ws/update-functions.sh"
    perform_update plugins-api abcdef1 ""
  ) > "$ws/update-target.out" 2>&1 || return 1
  assert_file_contains "$ws/update-target.out" 'plugins-api health checks passed' || return 1
  [[ $(grep -c 'Running health check script' "$ws/update-target.out") == 1 ]] || return 1
  assert_file_not_contains "$ws/mock-log/commands.log" 'docker logs.* (viewer|mongo|nginx)' || return 1
  cp "$ws/remotefalcon/compose.yaml" "$ws/before-failure.yaml"
  export MOCK_HTTP_CODE=503
  if (
    source "$ws/update-functions.sh"
    perform_update plugins-api badbeef ""
  ) > "$ws/update-failed.out" 2>&1; then return 1; fi
  cmp "$ws/before-failure.yaml" "$ws/remotefalcon/compose.yaml" || return 1
  assert_file_contains "$ws/update-failed.out" 'Restored plugins-api is still unhealthy' || return 1
  assert_file_contains "$ws/mock-log/commands.log" 'up -d --no-deps --force-recreate plugins-api'
}

test_health_check_uses_recent_logs() {
  assert_file_contains "$ROOT_DIR/health_check.sh" 'docker logs --since "\$\{HEALTH_LOG_SINCE:-10m\}"'
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

test_minio_migration_preserves_source() {
  local ws legacy_path migrated_path
  ws="$(make_workspace)"
  with_mocks "$ws"
  legacy_path="$ws/legacy-minio"
  mkdir -p "$legacy_path"
  printf 'legacy object data\n' > "$legacy_path/object.bin"
  printf 'MINIO_PATH=%s\n' "$legacy_path" >> "$ws/remotefalcon/.env"
  export MOCK_RUNNING_SERVICES="versitygw"
  export MOCK_LEGACY_MINIO=true

  (
    cd "$ws" || exit 1
    ./versitygw_init.sh
  ) || return 1

  [[ ! -e "$legacy_path" ]] || return 1
  migrated_path=$(find "$ws" -maxdepth 1 -type d -name 'legacy-minio.migrated-*' -print -quit)
  [[ -n "$migrated_path" && -f "$migrated_path/object.bin" ]] || return 1
  assert_file_contains "$ws/mock-log/commands.log" 'docker start remote-falcon-images.minio'
  assert_file_contains "$ws/mock-log/commands.log" 'docker network connect rf-network remote-falcon-images.minio'
  assert_file_contains "$ws/mock-log/commands.log" 'mc mirror --overwrite'
  assert_file_contains "$ws/mock-log/commands.log" 'mc --no-color diff'
  assert_file_contains "$ws/mock-log/commands.log" 'docker stop remote-falcon-images.minio'
  assert_file_not_contains "$ROOT_DIR/versitygw_init.sh" 'rm -rf.*MINIO'
  assert_file_not_contains "$ROOT_DIR/versitygw_init.sh" 'docker rm.*minio'
  unset MOCK_LEGACY_MINIO
}

test_health_check_empty_s3_bucket() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES="external-api ui plugins-api viewer control-panel cloudflared nginx mongo versitygw"
  export MOCK_BUCKET_EXISTS="true"
  export MOCK_BUCKET_POLICY_EXISTS="true"
  export MOCK_S3_LS_OUTPUT=""

  (
    cd "$ws" || exit 1
    ./health_check.sh 0s
  ) > "$ws/health.out" 2>&1 || true

  assert_file_contains "$ws/health.out" "No objects found in bucket 'remote-falcon-images'"
}

test_health_check_requires_s3_bucket() {
  local ws
  ws="$(make_workspace)"
  with_mocks "$ws"
  export MOCK_RUNNING_SERVICES="external-api ui plugins-api viewer control-panel cloudflared nginx mongo versitygw"
  export MOCK_BUCKET_EXISTS="false"
  export MOCK_BUCKET_POLICY_EXISTS="false"

  if (
    cd "$ws" || exit 1
    ./health_check.sh 0s
  ) > "$ws/health-missing-bucket.out" 2>&1; then
    return 1
  fi

  assert_file_contains "$ws/health-missing-bucket.out" "Bucket 'remote-falcon-images' not found"
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

test_configure_rf_has_no_archived_updater() {
  assert_file_not_contains "$ROOT_DIR/configure-rf.sh" 'git clone "https://\$\{GITHUB_PAT\}'
  assert_file_contains "$ROOT_DIR/configure-rf.sh" 'raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/install.sh'
  assert_file_not_contains "$ROOT_DIR/configure-rf.sh" 'raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/(shared_functions|update_containers)'
}

test_fresh_install_checks_each_deployed_service() {
  assert_file_contains "$ROOT_DIR/update_containers.sh" 'wait_for_service_deployment "\$service_name"'
  assert_file_contains "$ROOT_DIR/update_containers.sh" 'ps --services --filter status=running'
  assert_file_not_contains "$ROOT_DIR/update_containers.sh" '"\$HEALTH_CHECK_SCRIPT" 0s'
  assert_file_contains "$ROOT_DIR/configure-rf.sh" 'Container update failed. Aborting configuration.'
}

test_fresh_storage_is_initialized_and_required() {
  assert_file_contains "$ROOT_DIR/shared_functions.sh" 'The initializer is idempotent'
  assert_file_contains "$ROOT_DIR/shared_functions.sh" 'bash "\$SCRIPT_DIR/versitygw_init.sh"'
  assert_file_contains "$ROOT_DIR/health_check.sh" "Bucket.*not found.*versitygw_init.sh"
  assert_file_contains "$ROOT_DIR/health_check.sh" 'HEALTHY=false'
  assert_file_contains "$ROOT_DIR/tests/fresh-deployment-test.sh" './versitygw_init.sh && ./health_check.sh 0s'
}

test_noninteractive_mongo_upgrade_stays_on_current_major() {
  assert_file_contains "$ROOT_DIR/update_containers.sh" 'MongoDB major upgrade.*will not be applied automatically'
  assert_file_contains "$ROOT_DIR/update_containers.sh" 'replace_compose_tag "\$service_name" "\$LATEST_SAME_MAJOR"'
}

test_current_platform_runtime_configuration() {
  assert_file_contains "$ROOT_DIR/remotefalcon/compose.yaml" 'QUARKUS_MONGODB_CONNECTION_STRING=mongodb://\$\{MONGO_INITDB_ROOT_USERNAME\}:\$\{MONGO_INITDB_ROOT_PASSWORD\}@mongo:27017/remote-falcon\?authSource=admin'
  assert_file_contains "$ROOT_DIR/remotefalcon/compose.yaml" 'SPRING_DATA_MONGODB_URI=mongodb://\$\{MONGO_INITDB_ROOT_USERNAME\}:\$\{MONGO_INITDB_ROOT_PASSWORD\}@mongo:27017/remote-falcon\?authSource=admin'
  assert_file_contains "$ROOT_DIR/remotefalcon/compose.yaml" 'IMAGES_CDN_ENDPOINT=https://\$\{DOMAIN\}/\$\{IMAGES_S3_BUCKET\}'
  assert_file_contains "$ROOT_DIR/configure-rf.sh" 'Configuration completed with failed health checks.'
}

test_infrastructure_images_are_version_pinned() {
  assert_file_contains "$ROOT_DIR/remotefalcon/compose.yaml" 'image: nginx:1\.31\.6'
  assert_file_contains "$ROOT_DIR/remotefalcon/compose.yaml" 'image: cloudflare/cloudflared:2026\.9\.1'
  assert_file_contains "$ROOT_DIR/remotefalcon/compose.yaml" 'image: mongo:7\.0\.43'
  assert_file_contains "$ROOT_DIR/remotefalcon/compose.yaml" 'image: versity/versitygw:v1\.8\.0'
  assert_file_not_contains "$ROOT_DIR/remotefalcon/compose.yaml" 'image: (nginx|cloudflare/cloudflared|mongo|versity/versitygw):latest'
}

test_ci_has_pinned_static_validation() {
  assert_file_contains "$ROOT_DIR/.github/workflows/shell-tests.yml" 'shellcheck --severity=error'
  assert_file_contains "$ROOT_DIR/.github/workflows/shell-tests.yml" 'actionlint@v1\.7\.12'
  assert_file_contains "$ROOT_DIR/.github/workflows/shell-tests.yml" 'GOPATH.*actionlint'
  assert_file_contains "$ROOT_DIR/.github/workflows/shell-tests.yml" 'docker compose.*config -q'
  if grep -RE 'uses: [^ ]+@v[0-9]' "$ROOT_DIR/.github/workflows" "$ROOT_DIR/image-builder/.github/workflows"; then
    return 1
  fi
  assert_file_contains "$ROOT_DIR/requirements-docs.txt" '^mkdocs-material==[0-9]'
  assert_file_contains "$ROOT_DIR/requirements-docs.txt" '^mkdocs-glightbox==[0-9]'
  assert_file_contains "$ROOT_DIR/requirements-docs.txt" '^mkdocs-git-revision-date-localized-plugin==[0-9]'
}

test_fresh_deployment_harness_safety() {
  bash -n "$ROOT_DIR/tests/fresh-deployment-test.sh" || return 1
  assert_file_contains "$ROOT_DIR/tests/fresh-deployment-test.sh" 'Rerun with --replace-running on a dedicated test host'
  assert_file_contains "$ROOT_DIR/tests/fresh-deployment-test.sh" 'Refusing unsafe cleanup path'
  assert_file_contains "$ROOT_DIR/tests/fresh-deployment-test.sh" './configure-rf.sh -y --docker-mode manual'
  assert_file_contains "$ROOT_DIR/tests/fresh-deployment-test.sh" 'update_scripts.sh --version "\$VERSION"'
  assert_file_contains "$ROOT_DIR/tests/fresh-deployment-test.sh" 'ghcr.io/\$\{repo\}/\$\{service\}'
  assert_file_contains "$ROOT_DIR/tests/fresh-deployment-test.sh" 'remove_local_app_images'
}

test_release_archive_excludes_documentation() {
  assert_file_contains "$ROOT_DIR/.github/workflows/release.yml" 'install-manifest\.txt'
  assert_file_contains "$ROOT_DIR/.github/workflows/release.yml" 'release_paths'
  assert_file_not_contains "$ROOT_DIR/install-manifest.txt" '(^|[[:space:]])docs(/|[[:space:]])'
}

test_github_release_uses_documented_notes() {
  local output missing_version
  output="$TEST_TMP/github-release-notes.md"
  missing_version="$TEST_TMP/missing-version"

  bash "$ROOT_DIR/tests/extract-release-notes.sh" \
    "$ROOT_DIR/VERSION" "$ROOT_DIR/docs/release-notes.md" "$output" || return 1
  assert_file_contains "$output" "^## $(cat "$ROOT_DIR/VERSION")$"
  assert_file_contains "$output" '^-[[:space:]]+Added targeted health checks'
  assert_file_contains "$output" '^\[Full documentation\]'
  assert_file_not_contains "$output" '^## 2026\.9\.19\.3$'

  printf '1900.1.1\n' > "$missing_version"
  if bash "$ROOT_DIR/tests/extract-release-notes.sh" \
    "$missing_version" "$ROOT_DIR/docs/release-notes.md" "$TEST_TMP/missing-notes.md" >/dev/null 2>&1; then
    return 1
  fi

  assert_file_contains "$ROOT_DIR/.github/workflows/release.yml" 'body_path: github-release-notes\.md'
  assert_file_not_contains "$ROOT_DIR/.github/workflows/release.yml" 'generate_release_notes: true'
}

test_install_manifest_is_authoritative() {
  assert_file_contains "$ROOT_DIR/install-manifest.txt" '^executable configure-rf\.sh$'
  assert_file_contains "$ROOT_DIR/install-manifest.txt" '^template remotefalcon/compose\.yaml$'
  assert_file_contains "$ROOT_DIR/install-manifest.txt" '^release-dir tests$'
  assert_file_contains "$ROOT_DIR/install-manifest.txt" '^retired minio_init\.sh$'
  assert_file_contains "$ROOT_DIR/install-manifest.txt" '^retired revert\.sh$'
  assert_file_contains "$ROOT_DIR/update_scripts.sh" 'mapfile -t scripts.*install-manifest'
  assert_file_not_contains "$ROOT_DIR/update_scripts.sh" '^scripts=\('
}

test_fresh_remote_install_rebuilds_latest_tags() {
  assert_file_contains "$ROOT_DIR/configure-rf.sh" '\[ "\$pending_changes" = false \] && \[ "\$pending_arg_changes" = false \]'
  assert_file_contains "$ROOT_DIR/configure-rf.sh" 'Remote Falcon.*latest.*assuming new install.*run_workflow.sh'
}

test_remote_deploy_checks_built_services_before_full_stack() {
  assert_file_contains "$ROOT_DIR/run_workflow.sh" 'wait_for_deployed_services "\$\{services\[@\]\}"'
  assert_file_not_contains "$ROOT_DIR/run_workflow.sh" '"\$HEALTH_CHECK_SCRIPT" 0s'
  assert_file_contains "$ROOT_DIR/run_workflow.sh" 'up -d --force-recreate "\$\{services\[@\]\}"'
}

test_release_updater_merges_live_config() {
  local ws target
  ws="$(make_workspace)"
  with_mocks "$ws"
  target="$(mktemp -d "$TEST_TMP/update-target.XXXXXX")"
  mkdir -p "$target/remotefalcon"
  cat > "$target/remotefalcon/.env" <<'ENV'
DOMAIN=existing.example.com
MONGO_INITDB_ROOT_USERNAME=existing-user
MONGO_INITDB_ROOT_PASSWORD=existing-password
CUSTOM_SETTING=preserved
ENV
  cat > "$target/remotefalcon/compose.yaml" <<'COMPOSE'
services:
  mongo:
    image: mongo:4.4.29
  plugins-api:
    image: ghcr.io/example/plugins-api:abc1234
COMPOSE
  printf 'old nginx configuration\n' > "$target/remotefalcon/default.conf"
  printf 'old\n' > "$target/VERSION"
  printf '#!/bin/bash\n' > "$target/minio_init.sh"
  printf '#!/bin/bash\n' > "$target/revert.sh"

  RF_SKIP_UPDATE_TESTS=true bash "$ROOT_DIR/update_scripts.sh" \
    --install-from "$ROOT_DIR" --target "$target" --mode update || return 1

  [[ "$(cat "$target/VERSION")" == "$(cat "$ROOT_DIR/VERSION")" ]] || return 1
  assert_file_contains "$target/remotefalcon/.env" '^DOMAIN=existing\.example\.com$'
  assert_file_contains "$target/remotefalcon/.env" '^MONGO_INITDB_ROOT_USERNAME=existing-user$'
  assert_file_contains "$target/remotefalcon/.env" '^MONGO_INITDB_ROOT_PASSWORD=existing-password$'
  assert_file_contains "$target/remotefalcon/.env" '^CUSTOM_SETTING=preserved$'
  assert_file_contains "$target/remotefalcon/.env" '^RF_IMAGE_TAG_MODE=platform$'
  assert_file_contains "$target/remotefalcon/compose.yaml" '^    image: mongo:4\.4\.29$'
  assert_file_contains "$target/remotefalcon/compose.yaml" '^    image: ghcr\.io/example/plugins-api:abc1234$'
  assert_file_contains "$target/remotefalcon/compose.yaml" 'QUARKUS_MONGODB_CONNECTION_STRING='
  cmp "$target/remotefalcon/default.conf" "$ROOT_DIR/remotefalcon/default.conf" || return 1
  [[ ! -e "$target/remotefalcon/compose.yaml.new" ]] || return 1
  [[ ! -e "$target/remotefalcon/default.conf.new" ]] || return 1
  [[ -x "$target/configure-rf.sh" ]] || return 1
  [[ -f "$target/install-manifest.txt" ]] || return 1
  [[ -f "$target/LICENSE" ]] || return 1
  [[ ! -e "$target/minio_init.sh" ]] || return 1
  [[ ! -e "$target/revert.sh" ]] || return 1
  find "$target/remotefalcon-backups" -type f -name minio_init.sh -print -quit | grep -q . || return 1
  find "$target/remotefalcon-backups" -type f -name revert.sh -print -quit | grep -q . || return 1
  find "$target/remotefalcon-backups" -type f -path '*/remotefalcon/compose.yaml' -print -quit | grep -q . || return 1
  find "$target/remotefalcon-backups" -type f -path '*/remotefalcon/default.conf' -print -quit | grep -q . || return 1
  find "$target/remotefalcon-backups" -type f -path '*/remotefalcon/.env' -print -quit | grep -q . || return 1
}

test_release_updater_rejects_invalid_config() {
  local ws target before_env before_compose before_nginx
  ws="$(make_workspace)"
  with_mocks "$ws"
  target="$(mktemp -d "$TEST_TMP/update-invalid.XXXXXX")"
  mkdir -p "$target/remotefalcon"
  printf 'DOMAIN=existing.example.com\n' > "$target/remotefalcon/.env"
  printf 'services:\n  mongo:\n    image: mongo:4.4.29\n' > "$target/remotefalcon/compose.yaml"
  printf 'custom nginx configuration\n' > "$target/remotefalcon/default.conf"
  printf 'old\n' > "$target/VERSION"
  cp "$target/remotefalcon/.env" "$target/env.before"
  cp "$target/remotefalcon/compose.yaml" "$target/compose.before"
  cp "$target/remotefalcon/default.conf" "$target/nginx.before"
  before_env="$target/env.before"
  before_compose="$target/compose.before"
  before_nginx="$target/nginx.before"
  export MOCK_COMPOSE_CONFIG_FAIL=true

  if RF_SKIP_UPDATE_TESTS=true bash "$ROOT_DIR/update_scripts.sh" \
    --install-from "$ROOT_DIR" --target "$target" --mode update > "$target/update.out" 2>&1; then
    unset MOCK_COMPOSE_CONFIG_FAIL
    return 1
  fi
  unset MOCK_COMPOSE_CONFIG_FAIL
  cmp "$before_env" "$target/remotefalcon/.env" || return 1
  cmp "$before_compose" "$target/remotefalcon/compose.yaml" || return 1
  cmp "$before_nginx" "$target/remotefalcon/default.conf" || return 1
  assert_file_contains "$target/update.out" 'Merged Compose configuration failed validation; active configuration was not replaced'
}

run_test "bash syntax for managed scripts" test_bash_syntax
run_test "shared_functions.sh parses env and edits compose safely" test_shared_functions
run_test "shared_functions.sh reads current RF image tag" test_get_current_version
run_test "sync_repo_secrets.sh syncs transformed build secrets" test_sync_repo_secrets
run_test "run_workflow.sh triggers a mocked single-service build" test_run_workflow
run_test "run_workflow.sh triggers mocked multi-service pinned builds" test_run_workflow_multi_service_pinned
run_test "run_workflow.sh triggers a mocked all-service build" test_run_workflow_no_args
run_test "run_workflow.sh rejects invalid service arguments" test_run_workflow_invalid_argument
run_test "run_workflow.sh restores a failed deployment" test_run_workflow_rolls_back_failed_deploy
run_test "shared_functions.sh hides secrets in output" test_print_env_redacts_secrets
run_test "health_check.sh fails without .env" test_health_check_missing_env_fails
run_test "health_check.sh ignores stale log errors" test_health_check_uses_recent_logs
run_test "targeted health checks isolate the selected service" test_targeted_health_check
run_test "Quarkus runtime migration is targeted and idempotent" test_quarkus_environment_migration
run_test "control-panel runtime migration is targeted and idempotent" test_control_panel_environment_migration
run_test "image upgrades check only their service and roll back on HTTP failure" test_update_targeted_health_and_rollback
run_test "update_containers.sh supports mocked dry-run checks" test_update_containers_dry_run
run_test "setup_cloudflare.sh completes with mocked Cloudflare API" test_setup_cloudflare
run_test "versitygw_init.sh initializes mocked S3 resources" test_versitygw_init
run_test "MinIO migration verifies objects and preserves source data" test_minio_migration_preserves_source
run_test "health_check.sh reports an empty S3 bucket" test_health_check_empty_s3_bucket
run_test "health_check.sh fails when the S3 bucket is missing" test_health_check_requires_s3_bucket
run_test "configure-rf.sh exposes expected CLI help" test_configure_rf_help
run_test "configure-rf.sh has no archived updater" test_configure_rf_has_no_archived_updater
run_test "fresh installs validate deployed services individually" test_fresh_install_checks_each_deployed_service
run_test "fresh storage is initialized and required by health checks" test_fresh_storage_is_initialized_and_required
run_test "noninteractive MongoDB updates stay on the current major" test_noninteractive_mongo_upgrade_stays_on_current_major
run_test "compose supplies current platform runtime configuration" test_current_platform_runtime_configuration
run_test "infrastructure images use tested version tags" test_infrastructure_images_are_version_pinned
if [[ "${RF_RELEASE_PAYLOAD_TESTS:-false}" != true ]]; then
  run_test "CI uses pinned actions and static validators" test_ci_has_pinned_static_validation
fi
run_test "fresh deployment harness has guarded update and build modes" test_fresh_deployment_harness_safety
if [[ "${RF_RELEASE_PAYLOAD_TESTS:-false}" != true ]]; then
  run_test "release archive excludes documentation assets" test_release_archive_excludes_documentation
  run_test "GitHub releases use the documented version notes" test_github_release_uses_documented_notes
fi
run_test "installation manifest drives managed and retired files" test_install_manifest_is_authoritative
run_test "fresh remote installs rebuild latest application tags" test_fresh_remote_install_rebuilds_latest_tags
run_test "remote deployments validate built services before the full stack" test_remote_deploy_checks_built_services_before_full_stack
run_test "release updater merges live values into current configuration" test_release_updater_merges_live_config
run_test "release updater leaves live configuration unchanged after validation failure" test_release_updater_rejects_invalid_config

echo
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi
