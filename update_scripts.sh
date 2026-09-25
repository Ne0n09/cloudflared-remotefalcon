#!/bin/bash

# VERSION=2026.9.24.3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_FROM=""
TARGET_DIR="$SCRIPT_DIR"
MODE="update"
VERSION="latest"
REPOSITORY="${RF_INSTALL_REPOSITORY:-Ne0n09/cloudflared-remotefalcon}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --install-from) INSTALL_FROM="$2"; shift 2 ;;
    --target) TARGET_DIR="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--check] [--version TAG]"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$INSTALL_FROM" ]]; then
  if [[ "$MODE" == "check" ]]; then
    exec "$SCRIPT_DIR/install.sh" --check --target "$TARGET_DIR" --version "$VERSION" --no-configure
  fi
  exec "$SCRIPT_DIR/install.sh" --update --target "$TARGET_DIR" --version "$VERSION" --no-configure
fi

source_dir="$(cd "$INSTALL_FROM" && pwd)"
target_dir="$(mkdir -p "$TARGET_DIR" && cd "$TARGET_DIR" && pwd)"
new_version=$(tr -d '\r\n' < "$source_dir/VERSION")
current_version="none"
[[ -f "$target_dir/VERSION" ]] && current_version=$(tr -d '\r\n' < "$target_dir/VERSION")

if [[ "$MODE" == "check" ]]; then
  printf 'Installed: %s\nAvailable: %s\n' "$current_version" "$new_version"
  [[ "$current_version" == "$new_version" ]]
  exit
fi

manifest="$source_dir/install-manifest.txt"
[[ -f "$manifest" ]] || { echo "Release is missing install-manifest.txt" >&2; exit 1; }
if awk 'NF && $1 !~ /^#/ && (NF != 2 || $2 ~ /^\// || $2 ~ /(^|\/)\.\.($|\/)/ || $1 !~ /^(managed|executable|template|release-file|release-dir|retired)$/) { exit 1 }' "$manifest"; then
  :
else
  echo "Release contains an invalid install manifest." >&2
  exit 1
fi
mapfile -t scripts < <(awk '$1 == "executable" { print $2 }' "$manifest")
mapfile -t managed_files < <(awk '$1 == "managed" || $1 == "executable" { print $2 }' "$manifest")
mapfile -t template_files < <(awk '$1 == "template" { print $2 }' "$manifest")
mapfile -t obsolete_scripts < <(awk '$1 == "retired" { print $2 }' "$manifest")
for script in "${scripts[@]}"; do
  bash -n "$source_dir/$script"
done

if [[ "${RF_SKIP_UPDATE_TESTS:-false}" != true && -f "$source_dir/tests/shell_scripts_test.sh" ]]; then
  (cd "$source_dir" && bash tests/shell_scripts_test.sh)
fi

merge_env_configuration() {
  local existing="$1" template="$2" output="$3"
  if [[ ! -f "$existing" ]]; then
    cp "$template" "$output"
    chmod 600 "$output"
    return
  fi

  awk '
    NR==FNR {
      if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        key=substr($0, 1, index($0, "=")-1)
        values[key]=substr($0, index($0, "=")+1)
        if (!(key in ordered)) { order[++count]=key; ordered[key]=1 }
      }
      next
    }
    match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) {
      key=substr($0, 1, index($0, "=")-1)
      included[key]=1
      if (key in values) print key "=" values[key]
      else print
      next
    }
    { print }
    END {
      heading=0
      for (i=1; i<=count; i++) {
        key=order[i]
        if (!(key in included)) {
          if (!heading) { print ""; print "# Preserved settings from the previous .env"; heading=1 }
          print key "=" values[key]
        }
      }
    }
  ' "$existing" "$template" > "$output"
  chmod 600 "$output"
}

merge_compose_configuration() {
  local existing="$1" template="$2" output="$3"
  if [[ ! -f "$existing" ]]; then
    cp "$template" "$output"
    return
  fi

  # Use the new Compose structure while retaining every existing service image
  # reference, including CPU-compatible MongoDB pins and RF commit tags.
  awk '
    function service_name(line, value) {
      value=line
      sub(/^  /, "", value)
      sub(/:.*/, "", value)
      return value
    }
    NR==FNR {
      if ($0 ~ /^  [A-Za-z0-9_-]+:/) service=service_name($0)
      if (service != "" && $0 ~ /^    image:[[:space:]]*/) {
        value=$0
        sub(/^    image:[[:space:]]*/, "", value)
        images[service]=value
      }
      next
    }
    $0 ~ /^  [A-Za-z0-9_-]+:/ { service=service_name($0) }
    service in images && $0 ~ /^    image:[[:space:]]*/ {
      print "    image: " images[service]
      next
    }
    { print }
  ' "$existing" "$template" > "$output"
}

validate_compose_configuration() {
  local compose_file="$1" env_file="$2" line key
  local -a clean_environment=(env)
  command -v docker >/dev/null || { echo "Docker is required to validate the updated Compose configuration." >&2; return 1; }
  docker compose version >/dev/null 2>&1 || { echo "Docker Compose is required to validate the updated configuration." >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    key="${BASH_REMATCH[1]}"
    clean_environment+=(-u "$key")
  done < "$env_file"
  "${clean_environment[@]}" docker compose --env-file "$env_file" -f "$compose_file" config -q
}

backup_dir="$target_dir/remotefalcon-backups/scripts-$current_version-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 -p "$backup_dir"
installed=()
prepared_dir=""
rollback() {
  echo "Update failed; restoring the previous scripts." >&2
  for path in "${installed[@]}"; do
    relative="${path#$target_dir/}"
    if [[ -f "$backup_dir/$relative" ]]; then
      mkdir -p "$(dirname "$path")"
      cp -p "$backup_dir/$relative" "$path"
    else
      rm -f "$path"
    fi
  done
  [[ -z "$prepared_dir" ]] || rm -rf "$prepared_dir"
}
trap rollback ERR

# Remove retired managed scripts during updates. Back them up with the other
# managed files so a failed update can restore the previous installation.
for relative in "${obsolete_scripts[@]}"; do
  target_path="$target_dir/$relative"
  if [[ -f "$target_path" ]]; then
    mkdir -p "$backup_dir/$(dirname "$relative")"
    cp -p "$target_path" "$backup_dir/$relative"
    rm -f "$target_path"
    installed+=("$target_path")
  fi
done

managed=("${managed_files[@]}")
if [[ "$MODE" == "install" ]]; then
  managed+=("${template_files[@]}")
else
  prepared_dir=$(mktemp -d)
  mkdir -p "$prepared_dir/remotefalcon"
  merge_env_configuration \
    "$target_dir/remotefalcon/.env" \
    "$source_dir/remotefalcon/.env.example" \
    "$prepared_dir/remotefalcon/.env"
  merge_compose_configuration \
    "$target_dir/remotefalcon/compose.yaml" \
    "$source_dir/remotefalcon/compose.yaml" \
    "$prepared_dir/remotefalcon/compose.yaml"
  cp "$source_dir/remotefalcon/default.conf" "$prepared_dir/remotefalcon/default.conf"
  if ! validate_compose_configuration \
    "$prepared_dir/remotefalcon/compose.yaml" \
    "$prepared_dir/remotefalcon/.env"; then
    echo "Merged Compose configuration failed validation; active configuration was not replaced." >&2
    false
  fi

  for relative in remotefalcon/.env "${template_files[@]}"; do
    source_path="$prepared_dir/$relative"
    target_path="$target_dir/$relative"
    if [[ -f "$target_path" ]]; then
      mkdir -p "$backup_dir/$(dirname "$relative")"
      cp -p "$target_path" "$backup_dir/$relative"
    fi
    mkdir -p "$(dirname "$target_path")"
    cp -p "$source_path" "$target_path"
    installed+=("$target_path")
  done
  chmod 600 "$target_dir/remotefalcon/.env"
  rm -rf "$prepared_dir"
  prepared_dir=""
fi

for relative in "${managed[@]}"; do
  source_path="$source_dir/$relative"
  target_path="$target_dir/$relative"
  [[ -f "$source_path" ]] || { echo "Release is missing $relative" >&2; false; }
  if [[ -f "$target_path" ]]; then
    mkdir -p "$backup_dir/$(dirname "$relative")"
    cp -p "$target_path" "$backup_dir/$relative"
  fi
  mkdir -p "$(dirname "$target_path")"
  cp "$source_path" "$target_path"
  installed+=("$target_path")
done
chmod +x "${scripts[@]/#/$target_dir/}"
trap - ERR
echo "Installed cloudflared-remotefalcon $new_version."
[[ "$MODE" == "install" ]] || echo "Updated .env, compose.yaml, and default.conf; previous files are in $backup_dir."
