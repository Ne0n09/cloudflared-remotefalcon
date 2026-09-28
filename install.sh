#!/bin/bash
set -euo pipefail

REPOSITORY="${RF_INSTALL_REPOSITORY:-Ne0n09/cloudflared-remotefalcon}"
TARGET_DIR="${RF_INSTALL_DIR:-$PWD}"
MODE="install"
RUN_CONFIGURE=true
VERSION="latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET_DIR="$2"; shift 2 ;;
    --update) MODE="update"; shift ;;
    --check) MODE="check"; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --no-configure) RUN_CONFIGURE=false; shift ;;
    -h|--help)
      echo "Usage: $0 [--target DIR] [--update|--check] [--version TAG] [--no-configure]"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

ensure_update_docker_access() {
  [[ "$MODE" == "update" ]] || return 0
  command -v docker >/dev/null 2>&1 || {
    echo "Docker is not installed. Install Docker, then rerun this upgrade." >&2
    return 1
  }
  docker info >/dev/null 2>&1 && return 0

  if [[ $EUID -eq 0 ]]; then
    echo "Docker is installed, but the Docker service is unavailable. Start Docker, then rerun this upgrade." >&2
    return 1
  fi
  command -v sudo >/dev/null 2>&1 || {
    echo "The current user cannot access Docker and sudo is not installed." >&2
    echo "Ask an administrator to add this user to the docker group, then log out and back in." >&2
    return 1
  }
  if [[ ! -t 0 ]]; then
    echo "The current user cannot access Docker." >&2
    echo "Run this upgrade in an interactive terminal to be prompted to join the docker group." >&2
    return 2
  fi

  local current_user answer script_path
  local -a resume_args
  current_user="$(id -un)"
  echo "The user '$current_user' cannot currently access Docker."
  echo "Docker group membership grants root-level privileges on this host."
  read -r -p "Add '$current_user' to the docker group and continue the upgrade? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES|Yes) ;;
    *)
      echo "Upgrade cancelled before any installation files were changed."
      return 2
      ;;
  esac

  echo "Administrator access is required to update Docker group membership."
  sudo -v
  if ! sudo docker info >/dev/null 2>&1; then
    echo "Docker is unavailable even with administrator access. Start Docker, then rerun this upgrade." >&2
    return 1
  fi
  sudo groupadd --force docker
  sudo usermod -aG docker "$current_user"

  script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  resume_args=(--update --target "$TARGET_DIR" --version "$VERSION")
  [[ "$RUN_CONFIGURE" == true ]] || resume_args+=(--no-configure)
  echo "Docker access configured. Continuing the upgrade now..."
  echo "After the upgrade finishes, run 'newgrp docker' in this SSH session so subsequent Docker commands work without sudo."
  exec sudo -u "$current_user" -g docker env \
    "RF_INSTALL_REPOSITORY=$REPOSITORY" \
    "RF_DOCKER_GROUP_ADDED=true" \
    bash "$script_path" "${resume_args[@]}"
}

for command in curl tar sha256sum; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done

# Older installations commonly require sudo for Docker. Resolve that before
# downloading or changing any release files, then continue as the same user so
# upgraded files do not become owned by root.
ensure_update_docker_access

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT
if [[ "$VERSION" == "latest" ]]; then
  release_url="https://github.com/$REPOSITORY/releases/latest/download"
else
  release_url="https://github.com/$REPOSITORY/releases/download/$VERSION"
fi

echo "Downloading cloudflared-remotefalcon release ${VERSION}..."
curl -fsSL --retry 3 -o "$temporary_dir/cloudflared-remotefalcon.tar.gz" "$release_url/cloudflared-remotefalcon.tar.gz"
curl -fsSL --retry 3 -o "$temporary_dir/SHA256SUMS" "$release_url/SHA256SUMS"
(
  cd "$temporary_dir"
  grep ' cloudflared-remotefalcon.tar.gz$' SHA256SUMS | sha256sum -c -
  mkdir payload
  tar -xzf cloudflared-remotefalcon.tar.gz -C payload
)

bash "$temporary_dir/payload/update_scripts.sh" --install-from "$temporary_dir/payload" --target "$TARGET_DIR" --mode "$MODE"

if [[ "$RUN_CONFIGURE" == true ]]; then
  case "$MODE" in
    install) exec "$TARGET_DIR/configure-rf.sh" ;;
    update) exec "$TARGET_DIR/upgrade_installation.sh" ;;
  esac
fi
