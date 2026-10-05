#!/bin/bash
set -euo pipefail

REPOSITORY="${RF_INSTALL_REPOSITORY:-Ne0n09/cloudflared-remotefalcon}"
TARGET_DIR="${RF_INSTALL_DIR:-$PWD}"
TARGET_EXPLICIT=false
[[ -n "${RF_INSTALL_DIR:-}" ]] && TARGET_EXPLICIT=true
MODE="install"
RUN_CONFIGURE=true
VERSION="latest"
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET_DIR="$2"; TARGET_EXPLICIT=true; shift 2 ;;
    --update) MODE="update"; shift ;;
    --check) MODE="check"; shift ;;
    --force) FORCE=true; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --no-configure) RUN_CONFIGURE=false; shift ;;
    -h|--help)
      echo "Usage: $0 [--target DIR] [--update|--check] [--force] [--version TAG] [--no-configure]"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

is_remote_falcon_installation() {
  local candidate="$1"
  [[ -f "$candidate/configure-rf.sh" &&
     -f "$candidate/shared_functions.sh" &&
     -f "$candidate/update_containers.sh" &&
     -f "$candidate/remotefalcon/compose.yaml" &&
     -f "$candidate/remotefalcon/.env" ]]
}

resolve_update_target() {
  [[ "$MODE" == "update" ]] || return 0

  if [[ "$TARGET_EXPLICIT" == true ]]; then
    [[ -d "$TARGET_DIR" ]] || {
      echo "The specified upgrade target does not exist: $TARGET_DIR" >&2
      return 1
    }
    is_remote_falcon_installation "$TARGET_DIR" || {
      echo "The specified target is not a Remote Falcon installation: $TARGET_DIR" >&2
      echo "Expected the managed scripts, remotefalcon/compose.yaml, and remotefalcon/.env." >&2
      return 1
    }
  else
    local candidate current root script
    local -a candidates=()
    local -a preferred_candidates=(
      "${HOME:-}"
      "${HOME:-}/cloudflared-remotefalcon"
      "${HOME:-}/remotefalcon"
      /home/remotefalcon
      /opt/cloudflared-remotefalcon
      /srv/cloudflared-remotefalcon
    )
    local -a search_roots=("${HOME:-}" /home /opt /srv)
    declare -A seen=()

    # Prefer the current directory or one of its parents. This covers running
    # the installer from either the installation root or its remotefalcon dir.
    current="$PWD"
    while [[ -n "$current" ]]; do
      if is_remote_falcon_installation "$current"; then
        TARGET_DIR="$current"
        break
      fi
      [[ "$current" == / ]] && break
      current="$(dirname "$current")"
    done

    if ! is_remote_falcon_installation "$TARGET_DIR"; then
      for candidate in "${preferred_candidates[@]}"; do
        if [[ -n "$candidate" ]] && is_remote_falcon_installation "$candidate"; then
          TARGET_DIR="$candidate"
          break
        fi
      done
    fi

    if ! is_remote_falcon_installation "$TARGET_DIR"; then
      command -v find >/dev/null 2>&1 || {
        echo "Automatic installation discovery requires the find command." >&2
        echo "Install findutils or rerun with --target /path/to/cloudflared-remotefalcon." >&2
        return 1
      }
      for root in "${search_roots[@]}"; do
        [[ -n "$root" && -d "$root" ]] || continue
        while IFS= read -r -d '' script; do
          candidate="${script%/configure-rf.sh}"
          case "$candidate" in
            */remotefalcon-backups/*|*/vm-staging/*|*/.git/*|*/old/*) continue ;;
          esac
          is_remote_falcon_installation "$candidate" || continue
          [[ -n "${seen[$candidate]:-}" ]] && continue
          seen["$candidate"]=1
          candidates+=("$candidate")
        done < <(find "$root" -maxdepth 6 -type f -name configure-rf.sh -print0 2>/dev/null)
      done

      case "${#candidates[@]}" in
        0)
          echo "Could not locate an existing Remote Falcon installation." >&2
          echo "Rerun with --target /path/to/cloudflared-remotefalcon." >&2
          return 1
          ;;
        1) TARGET_DIR="${candidates[0]}" ;;
        *)
          echo "Multiple Remote Falcon installations were found:" >&2
          printf '  %s\n' "${candidates[@]}" >&2
          echo "Rerun with --target and the installation to upgrade." >&2
          return 1
          ;;
      esac
    fi
  fi

  TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
  cd "$TARGET_DIR"
  echo "Using Remote Falcon installation: $TARGET_DIR"
}

resolve_update_target

ensure_update_docker_access() {
  [[ "$MODE" == "update" ]] || return 0
  command -v docker >/dev/null 2>&1 || {
    echo "Docker is not installed. Install Docker, then rerun this upgrade." >&2
    return 1
  }
  if docker info >/dev/null 2>&1; then
    docker compose version >/dev/null 2>&1 || {
      echo "Docker Compose is not installed. Install the Docker Compose plugin, then rerun this upgrade." >&2
      return 1
    }
    return 0
  fi

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
  if ! sudo docker compose version >/dev/null 2>&1; then
    echo "Docker Compose is not installed. Install the Docker Compose plugin, then rerun this upgrade." >&2
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
if [[ "$MODE" == "update" ]]; then
  command -v openssl >/dev/null || {
    echo "Required command not found: openssl. Install OpenSSL, then rerun this upgrade." >&2
    exit 1
  }
fi

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

updater_args=(--install-from "$temporary_dir/payload" --target "$TARGET_DIR" --mode "$MODE")
[[ "$FORCE" == true ]] && updater_args+=(--force)

if [[ "$RUN_CONFIGURE" == true ]]; then
  case "$MODE" in
    install) next_script="$TARGET_DIR/configure-rf.sh" ;;
    update) next_script="$TARGET_DIR/upgrade_installation.sh" ;;
    *) next_script="" ;;
  esac
  if [[ -n "$next_script" ]]; then
    exec bash -c 'updater=$1; next_script=$2; shift 2; bash "$updater" "$@"; exec "$next_script"' \
      _ "$temporary_dir/payload/update_scripts.sh" "$next_script" "${updater_args[@]}"
  fi
fi

exec bash "$temporary_dir/payload/update_scripts.sh" "${updater_args[@]}"
