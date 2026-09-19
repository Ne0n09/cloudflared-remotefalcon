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

for command in curl tar sha256sum; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done

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

if [[ "$RUN_CONFIGURE" == true && "$MODE" == "install" ]]; then
  exec "$TARGET_DIR/configure-rf.sh"
fi
