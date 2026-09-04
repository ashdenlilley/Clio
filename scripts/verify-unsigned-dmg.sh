#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=release-common.sh
source "${SCRIPT_DIR}/release-common.sh"

DMG_PATH="${1:-}"
DSYM_PATH="${2:-}"
EXPECTED_BUNDLE_ID="${CLIO_EXPECTED_BUNDLE_ID:-olympus.clio.mac}"
EXPECTED_VERSION="${CLIO_EXPECTED_VERSION:-0.1.0}"
EXPECTED_BUILD="${CLIO_EXPECTED_BUILD:-1}"
EXPECTED_ARCHITECTURES="arm64 x86_64"
EXPECTED_HACK_LICENSE_SHA256="1f61bb7c790c59b4b0ecdf304628b94e42ae4c8020094a8c3da73381ab212623"
EXPECTED_MARKDOWN_LICENSE_SHA256="167beb36f181bd163c93c6feb45c68e5f9462fe1af55b278f7bfd1df20e673a3"
EXPECTED_CMARK_LICENSE_SHA256="c22e885f33b821bddb24cf007145e5540655b6c0f403e49e6c76a93c28e6d9a9"
EXPECTED_NOTICE_SHA256="acb5b10845d2e797d4e336418380700cb1d2612b959834bf5d625ea023448f2d"
EXPECTED_MARKDOWN_REVISION="3c6f9523da3a1ec2fd829673e472d95b8097a3b8"
EXPECTED_CMARK_REVISION="924936d0427cb25a61169739a7660230bffa6ea6"

if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
    echo "usage: $0 /absolute/path/to/Clio-<version>-unsigned.dmg [Clio.app.dSYM]" >&2
    exit 64
fi

for command_name in codesign file hdiutil lipo otool plutil shasum; do
    clio_require_command "${command_name}"
done

DMG_PATH="$(cd "$(dirname "${DMG_PATH}")" && pwd -P)/$(basename "${DMG_PATH}")"
if [[ -n "${DSYM_PATH}" ]]; then
    [[ -d "${DSYM_PATH}" ]] || clio_die "dSYM does not exist: ${DSYM_PATH}"
    DSYM_PATH="$(cd "$(dirname "${DSYM_PATH}")" && pwd -P)/$(basename "${DSYM_PATH}")"
fi

IMAGE_FORMAT="$(
    hdiutil imageinfo "${DMG_PATH}" \
        | awk -F': ' '/^[[:space:]]*Format: / { print $2; exit }'
)"
[[ "${IMAGE_FORMAT}" == "UDZO" ]] \
    || clio_die "expected a read-only zlib-compressed UDZO image, found ${IMAGE_FORMAT:-unknown}"

TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
[[ "${TEMP_ROOT}" != "/" ]] || clio_die "refusing to use the filesystem root for verification temporary files"
MOUNT_DIR="$(mktemp -d "${TEMP_ROOT}/clio-dmg-verify.XXXXXX")"
ATTACHED=0

cleanup() {
    local exit_code=$?
    if [[ "${ATTACHED}" -eq 1 ]]; then
        clio_detach_mount "${MOUNT_DIR}" || true
    fi
    rmdir "${MOUNT_DIR}" 2>/dev/null || true
    exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

hdiutil verify "${DMG_PATH}"
hdiutil attach "${DMG_PATH}" -readonly -nobrowse -mountpoint "${MOUNT_DIR}" -quiet
ATTACHED=1

APP_PATH="${MOUNT_DIR}/Clio.app"
PLIST_PATH="${APP_PATH}/Contents/Info.plist"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/Clio"

[[ -d "${APP_PATH}" && ! -L "${APP_PATH}" ]] || clio_die "Clio.app is missing or is a symlink"
[[ -f "${PLIST_PATH}" && ! -L "${PLIST_PATH}" ]] || clio_die "Info.plist is missing or is a symlink"
[[ -f "${EXECUTABLE_PATH}" && -x "${EXECUTABLE_PATH}" && ! -L "${EXECUTABLE_PATH}" ]] \
    || clio_die "Clio executable is missing, non-executable, or a symlink"
[[ -L "${MOUNT_DIR}/Applications" ]] || clio_die "Applications symlink is missing"
[[ "$(readlink "${MOUNT_DIR}/Applications")" == "/Applications" ]] \
    || clio_die "Applications symlink has the wrong destination"

UNEXPECTED_ROOT_ITEMS="$(
    find "${MOUNT_DIR}" -mindepth 1 -maxdepth 1 \
        ! -name Clio.app \
        ! -name Applications \
        -print
)"
[[ -z "${UNEXPECTED_ROOT_ITEMS}" ]] || {
    echo "error: DMG contains unexpected root items:" >&2
    echo "${UNEXPECTED_ROOT_ITEMS}" >&2
    exit 1
}

BUNDLE_ID="$(clio_plist_value "${PLIST_PATH}" CFBundleIdentifier)"
VERSION="$(clio_plist_value "${PLIST_PATH}" CFBundleShortVersionString)"
BUILD="$(clio_plist_value "${PLIST_PATH}" CFBundleVersion)"
ARCHITECTURES="$(clio_normalized_architectures "${EXECUTABLE_PATH}")"

[[ "${BUNDLE_ID}" == "${EXPECTED_BUNDLE_ID}" ]] \
    || clio_die "expected bundle ID ${EXPECTED_BUNDLE_ID}, found ${BUNDLE_ID}"
[[ "${VERSION}" == "${EXPECTED_VERSION}" ]] \
    || clio_die "expected version ${EXPECTED_VERSION}, found ${VERSION}"
[[ "${BUILD}" == "${EXPECTED_BUILD}" ]] \
    || clio_die "expected build ${EXPECTED_BUILD}, found ${BUILD}"
[[ "${ARCHITECTURES}" == "${EXPECTED_ARCHITECTURES}" ]] \
    || clio_die "expected exactly ${EXPECTED_ARCHITECTURES}, found ${ARCHITECTURES}"

# CODE_SIGNING_ALLOWED=NO leaves the application bundle unsigned. Modern linkers
# may still place an ad-hoc signature in each Mach-O, which is not a trusted
# distribution identity. Require that precise state and reject malformed code
# separately; a generic codesign failure is not proof that an app is unsigned.
[[ ! -e "${APP_PATH}/Contents/_CodeSignature" ]] \
    || clio_die "unsigned preview unexpectedly contains a bundle resource signature"

SIGNING_DESCRIPTION="$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1)" \
    || clio_die "could not inspect the executable's linker signature"
grep -q '^Signature=adhoc$' <<<"${SIGNING_DESCRIPTION}" \
    || clio_die "main executable is not linker-ad-hoc signed"
grep -q '^TeamIdentifier=not set$' <<<"${SIGNING_DESCRIPTION}" \
    || clio_die "unsigned preview unexpectedly contains a TeamIdentifier"
if grep -q '^Authority=' <<<"${SIGNING_DESCRIPTION}"; then
    clio_die "unsigned preview unexpectedly contains a signing authority"
fi

set +e
BUNDLE_VERIFY_DESCRIPTION="$(codesign --verify --deep --strict "${APP_PATH}" 2>&1)"
BUNDLE_VERIFY_STATUS=$?
set -e
[[ "${BUNDLE_VERIFY_STATUS}" -ne 0 ]] \
    || clio_die "unsigned preview unexpectedly has a valid bundle signature"
grep -q 'code object is not signed at all' <<<"${BUNDLE_VERIFY_DESCRIPTION}" \
    || clio_die "bundle signature is malformed rather than absent: ${BUNDLE_VERIFY_DESCRIPTION}"

MACHO_PATHS="$(
    find "${APP_PATH}/Contents" -type f -exec file {} \; \
        | awk -F: '/Mach-O/ {
            path = $1
            sub(/ \(for architecture.*$/, "", path)
            print path
        }' \
        | LC_ALL=C sort -u
)"
[[ "${MACHO_PATHS}" == "${EXECUTABLE_PATH}" ]] || {
    echo "error: unexpected nested Mach-O code requires an explicit signing/dependency audit:" >&2
    echo "${MACHO_PATHS}" >&2
    exit 1
}

UNEXPECTED_DEPENDENCIES="$(
    otool -L "${EXECUTABLE_PATH}" \
        | awk '/^[[:space:]]/ { print $1 }' \
        | grep -Ev '^(/System/Library/|/usr/lib/)' \
        || true
)"
[[ -z "${UNEXPECTED_DEPENDENCIES}" ]] || {
    echo "error: executable links unexpected non-system libraries:" >&2
    echo "${UNEXPECTED_DEPENDENCIES}" >&2
    exit 1
}

RESOURCE_ROOT="${APP_PATH}/Contents/Resources"
HACK_LICENSE="${RESOURCE_ROOT}/Fonts/LICENSE-Hack.md"
DEPENDENCY_NOTICES="${RESOURCE_ROOT}/ThirdPartyNotices"
NOTICE_PATH="${DEPENDENCY_NOTICES}/NOTICE.md"
MARKDOWN_LICENSE_PART_1="${DEPENDENCY_NOTICES}/Swift-Markdown-LICENSE-Part-1.txt"
MARKDOWN_LICENSE_PART_2="${DEPENDENCY_NOTICES}/Swift-Markdown-LICENSE-Part-2.txt"
CMARK_LICENSE_PART_1="${DEPENDENCY_NOTICES}/Swift-CMark-COPYING-Part-1.txt"
CMARK_LICENSE_PART_2="${DEPENDENCY_NOTICES}/Swift-CMark-COPYING-Part-2.txt"

for required_resource in \
    "${HACK_LICENSE}" \
    "${NOTICE_PATH}" \
    "${MARKDOWN_LICENSE_PART_1}" \
    "${MARKDOWN_LICENSE_PART_2}" \
    "${CMARK_LICENSE_PART_1}" \
    "${CMARK_LICENSE_PART_2}" \
    "${RESOURCE_ROOT}/AppIcon.icns"; do
    [[ -f "${required_resource}" && ! -L "${required_resource}" ]] \
        || clio_die "required release resource is missing or unsafe: ${required_resource}"
done

[[ "$(clio_sha256 "${HACK_LICENSE}")" == "${EXPECTED_HACK_LICENSE_SHA256}" ]] \
    || clio_die "bundled Hack licence does not match the reviewed source"
MARKDOWN_LICENSE_SHA256="$(
    cat "${MARKDOWN_LICENSE_PART_1}" "${MARKDOWN_LICENSE_PART_2}" | shasum -a 256 | awk '{ print $1 }'
)"
CMARK_LICENSE_SHA256="$(
    cat "${CMARK_LICENSE_PART_1}" "${CMARK_LICENSE_PART_2}" | shasum -a 256 | awk '{ print $1 }'
)"
[[ "${MARKDOWN_LICENSE_SHA256}" == "${EXPECTED_MARKDOWN_LICENSE_SHA256}" ]] \
    || clio_die "bundled swift-markdown licence is incomplete or changed"
[[ "${CMARK_LICENSE_SHA256}" == "${EXPECTED_CMARK_LICENSE_SHA256}" ]] \
    || clio_die "bundled swift-cmark notices are incomplete or changed"
[[ "$(clio_sha256 "${NOTICE_PATH}")" == "${EXPECTED_NOTICE_SHA256}" ]] \
    || clio_die "bundled third-party attribution notice is incomplete or changed"
grep -q "${EXPECTED_MARKDOWN_REVISION}" "${NOTICE_PATH}" \
    || clio_die "swift-markdown revision attribution is missing"
grep -q "${EXPECTED_CMARK_REVISION}" "${NOTICE_PATH}" \
    || clio_die "swift-cmark revision attribution is missing"

MARKDOWN_DOCUMENT_TYPE="$(
    clio_plist_value "${PLIST_PATH}" 'CFBundleDocumentTypes:0:LSItemContentTypes:0'
)"
[[ "${MARKDOWN_DOCUMENT_TYPE}" == "net.daringfireball.markdown" ]] \
    || clio_die "Markdown document registration is missing"

if [[ -n "${DSYM_PATH}" ]]; then
    DSYM_EXECUTABLE="${DSYM_PATH}/Contents/Resources/DWARF/Clio"
    [[ -f "${DSYM_EXECUTABLE}" ]] || clio_die "Clio DWARF file is missing from dSYM"
    DSYM_ARCHITECTURES="$(clio_normalized_architectures "${DSYM_EXECUTABLE}")"
    [[ "${DSYM_ARCHITECTURES}" == "${EXPECTED_ARCHITECTURES}" ]] \
        || clio_die "dSYM architectures do not match the universal app"

    EXECUTABLE_UUIDS="$(xcrun dwarfdump --uuid "${EXECUTABLE_PATH}" | awk '{ print $2 }' | LC_ALL=C sort)"
    DSYM_UUIDS="$(xcrun dwarfdump --uuid "${DSYM_PATH}" | awk '{ print $2 }' | LC_ALL=C sort)"
    [[ -n "${EXECUTABLE_UUIDS}" && "${EXECUTABLE_UUIDS}" == "${DSYM_UUIDS}" ]] \
        || clio_die "dSYM UUIDs do not match the executable"
fi

clio_detach_mount "${MOUNT_DIR}"
ATTACHED=0
rmdir "${MOUNT_DIR}"
trap - EXIT INT TERM

echo "Verified unsigned-internal Clio ${VERSION} (${BUILD}; ${BUNDLE_ID}) [${ARCHITECTURES}; ad-hoc linker signature; system libraries only]"
