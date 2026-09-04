#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${CLIO_VERSION:-0.1.0}"
BUILD_NUMBER="${CLIO_BUILD_NUMBER:-1}"
OUTPUT_DIR="${1:-${REPOSITORY_ROOT}/artifacts}"
DERIVED_DATA_PATH="${CLIO_DERIVED_DATA_PATH:-${REPOSITORY_ROOT}/.build/ReleaseDerivedData}"
ARTIFACT_BASENAME="Clio-${VERSION}-unsigned"
DMG_PATH="${OUTPUT_DIR}/${ARTIFACT_BASENAME}.dmg"
BUILD_LOG_PATH="${OUTPUT_DIR}/${ARTIFACT_BASENAME}-build.log"
MANIFEST_PATH="${OUTPUT_DIR}/${ARTIFACT_BASENAME}-manifest.json"
CHECKSUM_PATH="${DMG_PATH}.sha256"
DSYM_PATH="${OUTPUT_DIR}/Clio-${VERSION}.app.dSYM"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
DMG_PATH="${OUTPUT_DIR}/${ARTIFACT_BASENAME}.dmg"
BUILD_LOG_PATH="${OUTPUT_DIR}/${ARTIFACT_BASENAME}-build.log"
MANIFEST_PATH="${OUTPUT_DIR}/${ARTIFACT_BASENAME}-manifest.json"
CHECKSUM_PATH="${DMG_PATH}.sha256"
DSYM_PATH="${OUTPUT_DIR}/Clio-${VERSION}.app.dSYM"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clio-dmg-stage.XXXXXX")"
cleanup() {
    rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

cd "${REPOSITORY_ROOT}"

if [[ "${CLIO_SKIP_TESTS:-0}" != "1" ]]; then
    CLIO_DERIVED_DATA_PATH="${DERIVED_DATA_PATH}" "${SCRIPT_DIR}/test.sh"
fi

xcodegen generate

xcodebuild \
    -project Clio.xcodeproj \
    -scheme Clio \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    clean build | tee "${BUILD_LOG_PATH}"

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/Clio.app"
BUILT_DSYM_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/Clio.app.dSYM"
[[ -d "${APP_PATH}" ]] || { echo "error: Release Clio.app was not produced" >&2; exit 1; }

cp -R "${APP_PATH}" "${STAGING_DIR}/Clio.app"
ln -s /Applications "${STAGING_DIR}/Applications"

rm -f "${DMG_PATH}"
hdiutil create \
    -volname "Clio ${VERSION} — Unsigned Internal" \
    -srcfolder "${STAGING_DIR}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "${DMG_PATH}"

CLIO_EXPECTED_VERSION="${VERSION}" "${SCRIPT_DIR}/verify-unsigned-dmg.sh" "${DMG_PATH}"

if [[ -d "${BUILT_DSYM_PATH}" ]]; then
    rm -rf "${DSYM_PATH}"
    cp -R "${BUILT_DSYM_PATH}" "${DSYM_PATH}"
fi

SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
printf '%s  %s\n' "${SHA256}" "$(basename "${DMG_PATH}")" | tee "${CHECKSUM_PATH}"

COMMIT_SHA="$(git rev-parse HEAD)"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
ARCHITECTURES="$(lipo -archs "${APP_PATH}/Contents/MacOS/Clio")"
CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

plutil -create xml1 "${MANIFEST_PATH}"
plutil -insert artifact -string "$(basename "${DMG_PATH}")" "${MANIFEST_PATH}"
plutil -insert unsigned -bool YES "${MANIFEST_PATH}"
plutil -insert internalOnly -bool YES "${MANIFEST_PATH}"
plutil -insert version -string "${VERSION}" "${MANIFEST_PATH}"
plutil -insert build -string "${BUILD_NUMBER}" "${MANIFEST_PATH}"
plutil -insert bundleIdentifier -string "olympus.clio.mac" "${MANIFEST_PATH}"
plutil -insert commit -string "${COMMIT_SHA}" "${MANIFEST_PATH}"
plutil -insert xcode -string "${XCODE_VERSION}" "${MANIFEST_PATH}"
plutil -insert architectures -string "${ARCHITECTURES}" "${MANIFEST_PATH}"
plutil -insert sha256 -string "${SHA256}" "${MANIFEST_PATH}"
plutil -insert createdAt -string "${CREATED_AT}" "${MANIFEST_PATH}"
plutil -insert verification -string "hdiutil, layout, identity, version, architectures, unsigned state, licences" "${MANIFEST_PATH}"
plutil -convert json -r "${MANIFEST_PATH}"
plutil -extract artifact raw "${MANIFEST_PATH}" >/dev/null

echo "Created ${DMG_PATH}"
echo "Checksum ${CHECKSUM_PATH}"
echo "Manifest ${MANIFEST_PATH}"
if [[ -d "${DSYM_PATH}" ]]; then
    echo "Debug symbols ${DSYM_PATH}"
fi
