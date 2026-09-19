#!/bin/bash
set -euo pipefail

version_file="${1:-VERSION}"
notes_file="${2:-docs/release-notes.md}"
output_file="${3:-github-release-notes.md}"

[[ -f "$version_file" ]] || { echo "Version file not found: $version_file" >&2; exit 1; }
[[ -f "$notes_file" ]] || { echo "Release notes not found: $notes_file" >&2; exit 1; }

version=$(tr -d '\r\n' < "$version_file")
[[ -n "$version" ]] || { echo "Version is empty." >&2; exit 1; }

awk -v heading="## $version" '
  $0 == heading { found = 1 }
  found && $0 != heading && /^## / { exit }
  found { print }
  END { if (!found) exit 1 }
' "$notes_file" > "$output_file" || {
  rm -f "$output_file"
  echo "No release notes section found for $version." >&2
  exit 1
}

if ! grep -Eq '^-[[:space:]]+[^[:space:]]' "$output_file"; then
  rm -f "$output_file"
  echo "Release notes for $version do not contain any entries." >&2
  exit 1
fi

printf '\n[Full documentation](https://ne0n09.github.io/cloudflared-remotefalcon/release-notes/)\n' >> "$output_file"
