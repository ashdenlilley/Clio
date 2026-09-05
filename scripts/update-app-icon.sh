#!/bin/bash
set -euo pipefail

# Re-render the legacy catalog from the authoritative Icon Composer document.
# The native .icon is compiled directly by Xcode 26; Xcode 16 uses this catalog.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
XCODE_APP="${CLIO_ICON_XCODE_APP:-/Applications/Xcode.app}"
ICON_TOOL="${XCODE_APP}/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "${ICON_TOOL}" ]] || { echo "Icon Composer's ictool is required" >&2; exit 1; }

for size in 16 32 64 128 256 512 1024; do
    "${ICON_TOOL}" "${REPOSITORY_ROOT}/Clio/Resources/AppIcon.icon" \
        --export-image \
        --output-file "${REPOSITORY_ROOT}/Clio/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-${size}.png" \
        --platform macOS --rendition Default --width "${size}" --height "${size}" --scale 1
done
