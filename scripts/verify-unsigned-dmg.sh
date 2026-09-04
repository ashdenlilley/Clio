#!/bin/bash

set -euo pipefail

DMG_PATH="${1:-}"
EXPECTED_BUNDLE_ID="${CLIO_EXPECTED_BUNDLE_ID:-olympus.clio.mac}"
EXPECTED_VERSION="${CLIO_EXPECTED_VERSION:-0.1.0}"

if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
    echo "usage: $0 /absolute/path/to/Clio-<version>-unsigned.dmg" >&2
    exit 64
fi

DMG_PATH="$(cd "$(dirname "${DMG_PATH}")" && pwd)/$(basename "${DMG_PATH}")"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clio-dmg-mount.XXXXXX")"
ATTACHED=0

cleanup() {
    if [[ "${ATTACHED}" -eq 1 ]]; then
        hdiutil detach "${MOUNT_DIR}" -quiet || true
    fi
    rmdir "${MOUNT_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil verify "${DMG_PATH}"
hdiutil attach "${DMG_PATH}" -readonly -nobrowse -mountpoint "${MOUNT_DIR}" -quiet
ATTACHED=1

APP_PATH="${MOUNT_DIR}/Clio.app"
PLIST_PATH="${APP_PATH}/Contents/Info.plist"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/Clio"

[[ -d "${APP_PATH}" ]] || { echo "error: Clio.app is missing" >&2; exit 1; }
[[ -L "${MOUNT_DIR}/Applications" ]] || { echo "error: Applications symlink is missing" >&2; exit 1; }
[[ "$(readlink "${MOUNT_DIR}/Applications")" == "/Applications" ]] || {
    echo "error: Applications symlink has the wrong destination" >&2
    exit 1
}

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST_PATH}")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_PATH}")"
ARCHITECTURES="$(lipo -archs "${EXECUTABLE_PATH}")"

[[ "${BUNDLE_ID}" == "${EXPECTED_BUNDLE_ID}" ]] || {
    echo "error: expected bundle ID ${EXPECTED_BUNDLE_ID}, found ${BUNDLE_ID}" >&2
    exit 1
}
[[ "${VERSION}" == "${EXPECTED_VERSION}" ]] || {
    echo "error: expected version ${EXPECTED_VERSION}, found ${VERSION}" >&2
    exit 1
}
[[ " ${ARCHITECTURES} " == *" arm64 "* && " ${ARCHITECTURES} " == *" x86_64 "* ]] || {
    echo "error: expected universal arm64/x86_64 executable, found ${ARCHITECTURES}" >&2
    exit 1
}

if codesign --verify --deep --strict "${APP_PATH}" >/dev/null 2>&1; then
    echo "error: internal image unexpectedly contains a signed application" >&2
    exit 1
fi

find "${APP_PATH}/Contents/Resources" -name 'LICENSE-Hack.md' -print -quit | grep -q . || {
    echo "error: bundled Hack licence is missing" >&2
    exit 1
}

echo "Verified unsigned Clio ${VERSION} (${BUNDLE_ID}) [${ARCHITECTURES}]"

