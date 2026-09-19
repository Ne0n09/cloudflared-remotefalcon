#!/bin/bash
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

scripts=(configure-rf.sh generate_jwt.sh health_check.sh install.sh make_admin.sh minio_init.sh revert.sh run_workflow.sh setup_cloudflare.sh shared_functions.sh sync_repo_secrets.sh update_containers.sh update_scripts.sh versitygw_init.sh)
for script in "${scripts[@]}"; do
  bash -n "$source_dir/$script"
done

if [[ "${RF_SKIP_UPDATE_TESTS:-false}" != true && -x "$source_dir/tests/shell_scripts_test.sh" ]]; then
  (cd "$source_dir" && bash tests/shell_scripts_test.sh)
fi

backup_dir="$target_dir/remotefalcon-backups/scripts-$current_version-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 -p "$backup_dir"
installed=()
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
}
trap rollback ERR

managed=(VERSION "${scripts[@]}" remotefalcon/.env.example image-builder/.github/workflows/build.yml)
if [[ "$MODE" == "install" ]]; then
  managed+=(remotefalcon/compose.yaml remotefalcon/default.conf)
else
  # Updated templates are staged for review and never overwrite live configuration.
  mkdir -p "$target_dir/remotefalcon"
  cp "$source_dir/remotefalcon/compose.yaml" "$target_dir/remotefalcon/compose.yaml.new"
  cp "$source_dir/remotefalcon/default.conf" "$target_dir/remotefalcon/default.conf.new"
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
[[ "$MODE" == "install" ]] || echo "Review remotefalcon/compose.yaml.new and default.conf.new before applying template changes."
