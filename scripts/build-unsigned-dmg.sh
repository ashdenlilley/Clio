#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=release-common.sh
source "${SCRIPT_DIR}/release-common.sh"

VERSION="${CLIO_VERSION:-0.1.0}"
BUILD_NUMBER="${CLIO_BUILD_NUMBER:-1}"
BUNDLE_ID="olympus.clio.mac"
OUTPUT_ROOT="${1:-${REPOSITORY_ROOT}/artifacts}"
DERIVED_DATA_PATH="${CLIO_DERIVED_DATA_PATH:-${REPOSITORY_ROOT}/.build/ReleaseDerivedData}"
REPLACE_RELEASE="${CLIO_REPLACE_RELEASE:-0}"
ARTIFACT_BASENAME="Clio-${VERSION}-unsigned"
EXPECTED_MARKDOWN_REVISION="3c6f9523da3a1ec2fd829673e472d95b8097a3b8"
EXPECTED_CMARK_REVISION="924936d0427cb25a61169739a7660230bffa6ea6"
PACKAGE_RESOLVED="${REPOSITORY_ROOT}/Clio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

[[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
    || clio_die "CLIO_VERSION must contain two or three dot-separated integer components"
[[ "${BUILD_NUMBER}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
    || clio_die "CLIO_BUILD_NUMBER must contain one to three dot-separated integer components"
[[ "${REPLACE_RELEASE}" == "0" || "${REPLACE_RELEASE}" == "1" ]] \
    || clio_die "CLIO_REPLACE_RELEASE must be 0 or 1"
for command_name in ditto git hdiutil lipo plutil shasum xcodebuild xcodegen; do
    clio_require_command "${command_name}"
done

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
[[ -n "${DEVELOPER_DIR:-}" && -d "${DEVELOPER_DIR}" ]] \
    || clio_die "select a complete Xcode installation with DEVELOPER_DIR"

cd "${REPOSITORY_ROOT}"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] \
    || clio_die "release cuts require a clean Git worktree, including no untracked source files"

SOURCE_COMMIT="$(git rev-parse HEAD)"
SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
XCODEGEN_VERSION="$(xcodegen --version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${XCODEGEN_VERSION}" == "Version: 2.46.0" ]] \
    || clio_die "release cuts require XcodeGen 2.46.0, found ${XCODEGEN_VERSION}"

mkdir -p "${OUTPUT_ROOT}"
OUTPUT_ROOT="$(cd "${OUTPUT_ROOT}" && pwd -P)"
[[ "${OUTPUT_ROOT}" != "/" && "${OUTPUT_ROOT}" != "${REPOSITORY_ROOT}" ]] \
    || clio_die "the release output root must not be the filesystem or repository root"
if [[ "${OUTPUT_ROOT}" == "${REPOSITORY_ROOT}/"* ]]; then
    OUTPUT_RELATIVE_TO_REPOSITORY="${OUTPUT_ROOT#${REPOSITORY_ROOT}/}"
    git check-ignore -q -- "${OUTPUT_RELATIVE_TO_REPOSITORY}/" \
        || clio_die "an in-repository release output must be ignored by Git: ${OUTPUT_ROOT}"
fi
RELEASE_DIR="${OUTPUT_ROOT}/${ARTIFACT_BASENAME}"
if [[ -e "${RELEASE_DIR}" || -L "${RELEASE_DIR}" ]]; then
    [[ "${REPLACE_RELEASE}" == "1" ]] \
        || clio_die "release set already exists: ${RELEASE_DIR} (set CLIO_REPLACE_RELEASE=1 to archive and replace it)"
    [[ -d "${RELEASE_DIR}" && ! -L "${RELEASE_DIR}" ]] \
        || clio_die "refusing to replace a non-directory or symlink: ${RELEASE_DIR}"
fi

WORK_ROOT="$(mktemp -d "${OUTPUT_ROOT}/.${ARTIFACT_BASENAME}.work.XXXXXX")"
PUBLISH_DIR="${WORK_ROOT}/publish"
STAGING_DIR="${WORK_ROOT}/dmg-root"
mkdir -p "${PUBLISH_DIR}" "${STAGING_DIR}"
# DiskImages performs work in a helper process. These directories contain no
# secrets and need traverse permission for that helper.
chmod 755 "${WORK_ROOT}" "${PUBLISH_DIR}" "${STAGING_DIR}"

DMG_NAME="${ARTIFACT_BASENAME}.dmg"
BUILD_LOG_NAME="${ARTIFACT_BASENAME}-build.log"
VERIFICATION_LOG_NAME="${ARTIFACT_BASENAME}-verification.log"
SMOKE_LOG_NAME="${ARTIFACT_BASENAME}-launch-smoke.log"
MANIFEST_NAME="${ARTIFACT_BASENAME}-manifest.json"
CHECKSUM_NAME="${ARTIFACT_BASENAME}-SHA256SUMS"
DSYM_NAME="Clio-${VERSION}.app.dSYM.zip"
PACKAGE_RESOLVED_NAME="${ARTIFACT_BASENAME}-Package.resolved"

DMG_PATH="${PUBLISH_DIR}/${DMG_NAME}"
BUILD_LOG_PATH="${PUBLISH_DIR}/${BUILD_LOG_NAME}"
VERIFICATION_LOG_PATH="${PUBLISH_DIR}/${VERIFICATION_LOG_NAME}"
SMOKE_LOG_PATH="${PUBLISH_DIR}/${SMOKE_LOG_NAME}"
MANIFEST_PATH="${PUBLISH_DIR}/${MANIFEST_NAME}"
CHECKSUM_PATH="${PUBLISH_DIR}/${CHECKSUM_NAME}"
DSYM_ARCHIVE_PATH="${PUBLISH_DIR}/${DSYM_NAME}"
PACKAGE_RESOLVED_COPY_PATH="${PUBLISH_DIR}/${PACKAGE_RESOLVED_NAME}"
SUCCEEDED=0
BACKUP_DIR=""
PUBLISH_LOCK="${OUTPUT_ROOT}/.${ARTIFACT_BASENAME}.publish.lock"
LOCK_HELD=0

cleanup() {
    local exit_code=$?

    if [[ "${SUCCEEDED}" -eq 1 ]]; then
        if [[ -d "${WORK_ROOT}" ]]; then
            case "${WORK_ROOT}" in
                "${OUTPUT_ROOT}"/."${ARTIFACT_BASENAME}".work.*)
                    rm -rf -- "${WORK_ROOT}"
                    ;;
                *)
                    echo "warning: refusing to remove unexpected release work path ${WORK_ROOT}" >&2
                    ;;
            esac
        fi
    elif [[ -d "${WORK_ROOT}" ]]; then
        FAILURE_DIR="${OUTPUT_ROOT}/${ARTIFACT_BASENAME}.failed-${CREATED_AT//[:]/}-$$"
        if [[ ! -e "${FAILURE_DIR}" && ! -L "${FAILURE_DIR}" ]]; then
            if mv "${WORK_ROOT}" "${FAILURE_DIR}"; then
                echo "Release failed; recoverable build state retained at ${FAILURE_DIR}" >&2
            else
                echo "Release failed; could not archive work state; inspect ${WORK_ROOT}" >&2
            fi
        else
            echo "Release failed; recoverable build state retained at ${WORK_ROOT}" >&2
        fi
    fi

    if [[ "${LOCK_HELD}" -eq 1 ]]; then
        case "${PUBLISH_LOCK}" in
            "${OUTPUT_ROOT}"/."${ARTIFACT_BASENAME}".publish.lock)
                rmdir "${PUBLISH_LOCK}" 2>/dev/null \
                    || echo "warning: could not remove publication lock ${PUBLISH_LOCK}" >&2
                ;;
            *)
                echo "warning: refusing to remove unexpected publication lock ${PUBLISH_LOCK}" >&2
                ;;
        esac
    fi

    exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcodegen generate
git diff --exit-code -- Clio.xcodeproj project.yml \
    || clio_die "xcodegen changed the checked-in project; commit the generated project before cutting a release"
clio_require_exact_package_lock "${PACKAGE_RESOLVED}"

MARKDOWN_REVISION="$(clio_resolved_revision "${PACKAGE_RESOLVED}" swift-markdown)" \
    || clio_die "swift-markdown is missing from Package.resolved"
CMARK_REVISION="$(clio_resolved_revision "${PACKAGE_RESOLVED}" swift-cmark)" \
    || clio_die "swift-cmark is missing from Package.resolved"
[[ "${MARKDOWN_REVISION}" == "${EXPECTED_MARKDOWN_REVISION}" ]] \
    || clio_die "unexpected swift-markdown revision ${MARKDOWN_REVISION}"
[[ "${CMARK_REVISION}" == "${EXPECTED_CMARK_REVISION}" ]] \
    || clio_die "unexpected swift-cmark revision ${CMARK_REVISION}"
PACKAGE_RESOLVED_SHA256="$(clio_sha256 "${PACKAGE_RESOLVED}")"
ditto "${PACKAGE_RESOLVED}" "${PACKAGE_RESOLVED_COPY_PATH}"

CLIO_DERIVED_DATA_PATH="${DERIVED_DATA_PATH}" \
CLIO_SKIP_RELEASE_BUILD=1 \
    "${SCRIPT_DIR}/test.sh"

{
    echo "Clio unsigned-internal Release build"
    echo "commit=${SOURCE_COMMIT}"
    echo "sourceDateEpoch=${SOURCE_DATE_EPOCH}"
    echo "version=${VERSION}"
    echo "build=${BUILD_NUMBER}"
    echo "xcode=${XCODE_VERSION}"
    echo "xcodegen=${XCODEGEN_VERSION}"
    echo "packageResolvedSha256=${PACKAGE_RESOLVED_SHA256}"
    xcodebuild \
        -project Clio.xcodeproj \
        -scheme Clio \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "${DERIVED_DATA_PATH}" \
        -onlyUsePackageVersionsFromResolvedFile \
        -disableAutomaticPackageResolution \
        MARKETING_VERSION="${VERSION}" \
        CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=NO \
        ARCHS="arm64 x86_64" \
        clean build
} 2>&1 | tee "${BUILD_LOG_PATH}"

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/Clio.app"
BUILT_DSYM_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/Clio.app.dSYM"
[[ -d "${APP_PATH}" ]] || clio_die "Release Clio.app was not produced"
[[ -d "${BUILT_DSYM_PATH}" ]] || clio_die "matching Release dSYM was not produced"

ditto "${APP_PATH}" "${STAGING_DIR}/Clio.app"
ln -s /Applications "${STAGING_DIR}/Applications"

# Normalize source item timestamps to the immutable commit time. hdiutil still
# owns container metadata, so the checksum identifies this exact cut rather
# than claiming byte-for-byte identity across different macOS/Xcode versions.
TOUCH_STAMP="$(date -u -r "${SOURCE_DATE_EPOCH}" '+%Y%m%d%H%M.%S')"
find "${STAGING_DIR}" -exec touch -h -t "${TOUCH_STAMP}" {} +

hdiutil create \
    -volname "Clio ${VERSION} - Unsigned Internal" \
    -srcfolder "${STAGING_DIR}" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -nospotlight \
    -anyowners \
    "${DMG_PATH}"

CLIO_EXPECTED_BUNDLE_ID="${BUNDLE_ID}" \
CLIO_EXPECTED_VERSION="${VERSION}" \
CLIO_EXPECTED_BUILD="${BUILD_NUMBER}" \
    "${SCRIPT_DIR}/verify-unsigned-dmg.sh" "${DMG_PATH}" "${BUILT_DSYM_PATH}" \
        | tee "${VERIFICATION_LOG_PATH}"

CLIO_EXPECTED_BUNDLE_ID="${BUNDLE_ID}" \
CLIO_EXPECTED_VERSION="${VERSION}" \
CLIO_EXPECTED_BUILD="${BUILD_NUMBER}" \
CLIO_SMOKE_SECONDS=5 \
    "${SCRIPT_DIR}/smoke-unsigned-dmg.sh" "${DMG_PATH}" "${SMOKE_LOG_PATH}"

DSYM_STAGING_PATH="${WORK_ROOT}/Clio.app.dSYM"
ditto "${BUILT_DSYM_PATH}" "${DSYM_STAGING_PATH}"
find "${DSYM_STAGING_PATH}" -exec touch -h -t "${TOUCH_STAMP}" {} +
ditto -c -k --sequesterRsrc --keepParent "${DSYM_STAGING_PATH}" "${DSYM_ARCHIVE_PATH}"
ARCHITECTURES="$(clio_normalized_architectures "${APP_PATH}/Contents/MacOS/Clio")"
[[ "${ARCHITECTURES}" == "arm64 x86_64" ]] \
    || clio_die "built executable is not exactly arm64 and x86_64"
DMG_SHA256="$(clio_sha256 "${DMG_PATH}")"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] \
    || clio_die "build changed the source tree; refusing to publish artifacts for an ambiguous commit"

plutil -create xml1 "${MANIFEST_PATH}"
plutil -insert schemaVersion -integer 1 "${MANIFEST_PATH}"
plutil -insert artifact -string "${DMG_NAME}" "${MANIFEST_PATH}"
plutil -insert checksumFile -string "${CHECKSUM_NAME}" "${MANIFEST_PATH}"
plutil -insert buildLog -string "${BUILD_LOG_NAME}" "${MANIFEST_PATH}"
plutil -insert verificationLog -string "${VERIFICATION_LOG_NAME}" "${MANIFEST_PATH}"
plutil -insert launchSmokeLog -string "${SMOKE_LOG_NAME}" "${MANIFEST_PATH}"
plutil -insert debugSymbols -string "${DSYM_NAME}" "${MANIFEST_PATH}"
plutil -insert packageResolved -string "${PACKAGE_RESOLVED_NAME}" "${MANIFEST_PATH}"
plutil -insert unsigned -bool YES "${MANIFEST_PATH}"
plutil -insert internalOnly -bool YES "${MANIFEST_PATH}"
plutil -insert signingModel -string "unsigned-app-bundle-with-linker-adhoc-mach-o" "${MANIFEST_PATH}"
plutil -insert version -string "${VERSION}" "${MANIFEST_PATH}"
plutil -insert build -string "${BUILD_NUMBER}" "${MANIFEST_PATH}"
plutil -insert bundleIdentifier -string "${BUNDLE_ID}" "${MANIFEST_PATH}"
plutil -insert commit -string "${SOURCE_COMMIT}" "${MANIFEST_PATH}"
plutil -insert sourceTreeClean -bool YES "${MANIFEST_PATH}"
plutil -insert sourceDateEpoch -string "${SOURCE_DATE_EPOCH}" "${MANIFEST_PATH}"
plutil -insert createdAt -string "${CREATED_AT}" "${MANIFEST_PATH}"
plutil -insert xcode -string "${XCODE_VERSION}" "${MANIFEST_PATH}"
plutil -insert xcodegen -string "${XCODEGEN_VERSION}" "${MANIFEST_PATH}"
plutil -insert architectures -string "${ARCHITECTURES}" "${MANIFEST_PATH}"
plutil -insert dmgSha256 -string "${DMG_SHA256}" "${MANIFEST_PATH}"
plutil -insert packageResolvedSha256 -string "${PACKAGE_RESOLVED_SHA256}" "${MANIFEST_PATH}"
plutil -insert testsRun -bool YES "${MANIFEST_PATH}"
plutil -insert launchSmokeSeconds -integer 5 "${MANIFEST_PATH}"
plutil -insert dependencies -dictionary "${MANIFEST_PATH}"
plutil -insert dependencies.swiftMarkdown -dictionary "${MANIFEST_PATH}"
plutil -insert dependencies.swiftMarkdown.revision -string "${MARKDOWN_REVISION}" "${MANIFEST_PATH}"
plutil -insert dependencies.swiftCMark -dictionary "${MANIFEST_PATH}"
plutil -insert dependencies.swiftCMark.revision -string "${CMARK_REVISION}" "${MANIFEST_PATH}"
plutil -insert verification -string "UDZO/layout, identity/version/build, exact architectures, unsigned/ad-hoc state, nested code, linked libraries, complete licence hashes, matching dSYM UUIDs, isolated process launch" "${MANIFEST_PATH}"
plutil -insert reproducibility -string "clean commit, locked dependency revisions, recorded toolchain, normalized staged timestamps; SHA-256 identifies the exact hdiutil container" "${MANIFEST_PATH}"
plutil -convert json -r "${MANIFEST_PATH}"

(
    cd "${PUBLISH_DIR}"
    shasum -a 256 \
        "${DMG_NAME}" \
        "${BUILD_LOG_NAME}" \
        "${VERIFICATION_LOG_NAME}" \
        "${SMOKE_LOG_NAME}" \
        "${DSYM_NAME}" \
        "${PACKAGE_RESOLVED_NAME}" \
        "${MANIFEST_NAME}" \
        >"${CHECKSUM_NAME}"
)

"${SCRIPT_DIR}/verify-release-artifacts.sh" "${PUBLISH_DIR}"

# Publish the verified set with a single same-filesystem directory rename. An
# exclusive directory lock serializes cooperating release cuts. An explicit
# replacement archives the previous complete set; it never deletes it.
mkdir "${PUBLISH_LOCK}" \
    || clio_die "another cut is publishing this version, or a stale lock needs review: ${PUBLISH_LOCK}"
LOCK_HELD=1
if [[ -e "${RELEASE_DIR}" || -L "${RELEASE_DIR}" ]]; then
    [[ "${REPLACE_RELEASE}" == "1" ]] || clio_die "release set appeared during build: ${RELEASE_DIR}"
    [[ -d "${RELEASE_DIR}" && ! -L "${RELEASE_DIR}" ]] \
        || clio_die "refusing to replace a non-directory or symlink: ${RELEASE_DIR}"
    BACKUP_DIR="${OUTPUT_ROOT}/${ARTIFACT_BASENAME}.previous-${CREATED_AT//[:]/}-$$"
    [[ ! -e "${BACKUP_DIR}" && ! -L "${BACKUP_DIR}" ]] \
        || clio_die "backup path already exists: ${BACKUP_DIR}"
    mv "${RELEASE_DIR}" "${BACKUP_DIR}"
    echo "Archived previous release set at ${BACKUP_DIR}"
fi

case "${STAGING_DIR}" in
    "${WORK_ROOT}"/dmg-root)
        rm -rf -- "${STAGING_DIR}"
        ;;
    *)
        clio_die "refusing to remove unexpected staging path ${STAGING_DIR}"
        ;;
esac
if ! mv "${PUBLISH_DIR}" "${RELEASE_DIR}"; then
    if [[ -n "${BACKUP_DIR}" && ! -e "${RELEASE_DIR}" && ! -L "${RELEASE_DIR}" && -d "${BACKUP_DIR}" ]]; then
        if mv "${BACKUP_DIR}" "${RELEASE_DIR}"; then
            echo "Restored previous release set after publication failure: ${RELEASE_DIR}" >&2
            BACKUP_DIR=""
        else
            echo "Could not restore the archived release set; recover it from ${BACKUP_DIR}" >&2
        fi
    fi
    clio_die "could not publish verified release set"
fi
SUCCEEDED=1

echo "Published verified release set ${RELEASE_DIR}"
echo "DMG ${RELEASE_DIR}/${DMG_NAME}"
echo "Checksums ${RELEASE_DIR}/${CHECKSUM_NAME}"
echo "Manifest ${RELEASE_DIR}/${MANIFEST_NAME}"
echo "Debug symbols ${RELEASE_DIR}/${DSYM_NAME}"
