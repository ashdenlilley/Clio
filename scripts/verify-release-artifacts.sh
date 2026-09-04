#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=release-common.sh
source "${SCRIPT_DIR}/release-common.sh"

RELEASE_DIR="${1:-}"
if [[ -z "${RELEASE_DIR}" || ! -d "${RELEASE_DIR}" ]]; then
    echo "usage: $0 /absolute/path/to/Clio-<version>-unsigned" >&2
    exit 64
fi

for command_name in ditto plutil shasum unzip zipinfo; do
    clio_require_command "${command_name}"
done

RELEASE_DIR="$(cd "${RELEASE_DIR}" && pwd -P)"
MANIFEST_CANDIDATES="$(find "${RELEASE_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*-manifest.json' -print)"
[[ "$(printf '%s\n' "${MANIFEST_CANDIDATES}" | sed '/^$/d' | wc -l | tr -d ' ')" == "1" ]] \
    || clio_die "release set must contain exactly one manifest"
MANIFEST_PATH="${MANIFEST_CANDIDATES}"

manifest_value() {
    plutil -extract "$1" raw "${MANIFEST_PATH}" 2>/dev/null \
        || clio_die "manifest is missing required key: $1"
}

SCHEMA_VERSION="$(manifest_value schemaVersion)"
ARTIFACT_NAME="$(manifest_value artifact)"
CHECKSUM_NAME="$(manifest_value checksumFile)"
BUILD_LOG_NAME="$(manifest_value buildLog)"
TEST_LOG_NAME="$(manifest_value testLog)"
TEST_RESULTS_NAME="$(manifest_value testResults)"
VERIFICATION_LOG_NAME="$(manifest_value verificationLog)"
SMOKE_LOG_NAME="$(manifest_value launchSmokeLog)"
DSYM_NAME="$(manifest_value debugSymbols)"
PACKAGE_RESOLVED_NAME="$(manifest_value packageResolved)"
VERSION="$(manifest_value version)"
BUILD="$(manifest_value build)"
BUNDLE_ID="$(manifest_value bundleIdentifier)"
ARCHITECTURES="$(manifest_value architectures)"
UNSIGNED="$(manifest_value unsigned)"
INTERNAL_ONLY="$(manifest_value internalOnly)"
SIGNING_MODEL="$(manifest_value signingModel)"
DMG_SHA256="$(manifest_value dmgSha256)"
SOURCE_COMMIT="$(manifest_value commit)"
SOURCE_TREE_CLEAN="$(manifest_value sourceTreeClean)"
SOURCE_DATE_EPOCH="$(manifest_value sourceDateEpoch)"
CREATED_AT="$(manifest_value createdAt)"
XCODE_VERSION="$(manifest_value xcode)"
XCODEGEN_VERSION="$(manifest_value xcodegen)"
TESTS_RUN="$(manifest_value testsRun)"
LAUNCH_SMOKE_SECONDS="$(manifest_value launchSmokeSeconds)"
PACKAGE_RESOLVED_SHA256="$(manifest_value packageResolvedSha256)"
MARKDOWN_REVISION="$(manifest_value dependencies.swiftMarkdown.revision)"
CMARK_REVISION="$(manifest_value dependencies.swiftCMark.revision)"

[[ "${SCHEMA_VERSION}" == "1" ]] || clio_die "unsupported release manifest schema ${SCHEMA_VERSION}"
[[ "${UNSIGNED}" == "true" && "${INTERNAL_ONLY}" == "true" ]] \
    || clio_die "manifest does not identify an unsigned internal-only release"
[[ "${SIGNING_MODEL}" == "unsigned-app-bundle-with-linker-adhoc-mach-o" ]] \
    || clio_die "unexpected signing model: ${SIGNING_MODEL}"
[[ "${ARCHITECTURES}" == "arm64 x86_64" ]] \
    || clio_die "manifest does not declare exactly arm64 and x86_64"
[[ "${SOURCE_TREE_CLEAN}" == "true" ]] || clio_die "release was not cut from a clean source tree"
[[ "${TESTS_RUN}" == "true" ]] || clio_die "release manifest says the test gate was skipped"
[[ "${LAUNCH_SMOKE_SECONDS}" == "5" ]] || clio_die "release did not run the required five-second launch smoke"
[[ "${SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || clio_die "manifest commit is not a full Git SHA"
[[ "${SOURCE_DATE_EPOCH}" =~ ^[1-9][0-9]*$ ]] || clio_die "manifest source timestamp is malformed"
[[ "${CREATED_AT}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || clio_die "manifest creation timestamp is malformed"
[[ "${XCODE_VERSION}" =~ ^Xcode\ [0-9]+(\.[0-9]+){1,2}\ Build\ version\ [A-Za-z0-9.]+$ ]] \
    || clio_die "manifest Xcode version is malformed: ${XCODE_VERSION}"
[[ "${XCODEGEN_VERSION}" == "Version: 2.46.0" ]] \
    || clio_die "release did not use XcodeGen 2.46.0"
[[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
    || clio_die "manifest version is malformed: ${VERSION}"
[[ "${BUILD}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
    || clio_die "manifest build number is malformed: ${BUILD}"
[[ "${BUNDLE_ID}" == "olympus.clio.mac" ]] \
    || clio_die "unexpected bundle identifier in manifest: ${BUNDLE_ID}"
[[ "${DMG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || clio_die "manifest DMG checksum is malformed"
[[ "${PACKAGE_RESOLVED_SHA256}" =~ ^[0-9a-f]{64}$ ]] \
    || clio_die "manifest Package.resolved checksum is malformed"
[[ "${MARKDOWN_REVISION}" == "3c6f9523da3a1ec2fd829673e472d95b8097a3b8" ]] \
    || clio_die "unexpected swift-markdown revision in manifest"
[[ "${CMARK_REVISION}" == "924936d0427cb25a61169739a7660230bffa6ea6" ]] \
    || clio_die "unexpected swift-cmark revision in manifest"
[[ "${ARTIFACT_NAME}" == "Clio-${VERSION}-unsigned.dmg" ]] \
    || clio_die "DMG filename does not match the manifest version"
[[ "${CHECKSUM_NAME}" == "Clio-${VERSION}-unsigned-SHA256SUMS" ]] \
    || clio_die "checksum filename does not match the manifest version"
[[ "${BUILD_LOG_NAME}" == "Clio-${VERSION}-unsigned-build.log" ]] \
    || clio_die "build-log filename does not match the manifest version"
[[ "${TEST_LOG_NAME}" == "Clio-${VERSION}-unsigned-tests.log" ]] \
    || clio_die "test-log filename does not match the manifest version"
[[ "${TEST_RESULTS_NAME}" == "Clio-${VERSION}-unsigned-tests.xcresult.zip" ]] \
    || clio_die "test-results filename does not match the manifest version"
[[ "${VERIFICATION_LOG_NAME}" == "Clio-${VERSION}-unsigned-verification.log" ]] \
    || clio_die "verification-log filename does not match the manifest version"
[[ "${SMOKE_LOG_NAME}" == "Clio-${VERSION}-unsigned-launch-smoke.log" ]] \
    || clio_die "launch-smoke filename does not match the manifest version"
[[ "${DSYM_NAME}" == "Clio-${VERSION}.app.dSYM.zip" ]] \
    || clio_die "dSYM filename does not match the manifest version"
[[ "${PACKAGE_RESOLVED_NAME}" == "Clio-${VERSION}-unsigned-Package.resolved" ]] \
    || clio_die "Package.resolved filename does not match the manifest version"
[[ "$(basename "${MANIFEST_PATH}")" == "Clio-${VERSION}-unsigned-manifest.json" ]] \
    || clio_die "manifest filename does not match its version"

for artifact_name in \
    "${ARTIFACT_NAME}" \
    "${CHECKSUM_NAME}" \
    "${BUILD_LOG_NAME}" \
    "${TEST_LOG_NAME}" \
    "${TEST_RESULTS_NAME}" \
    "${VERIFICATION_LOG_NAME}" \
    "${SMOKE_LOG_NAME}" \
    "${DSYM_NAME}" \
    "${PACKAGE_RESOLVED_NAME}" \
    "$(basename "${MANIFEST_PATH}")"; do
    clio_require_safe_basename "${artifact_name}"
    [[ -f "${RELEASE_DIR}/${artifact_name}" && ! -L "${RELEASE_DIR}/${artifact_name}" ]] \
        || clio_die "release artifact is missing or is a symlink: ${artifact_name}"
done

EXPECTED_FILE_LIST="$(
    printf '%s\n' \
        "${ARTIFACT_NAME}" \
        "${BUILD_LOG_NAME}" \
        "${TEST_LOG_NAME}" \
        "${TEST_RESULTS_NAME}" \
        "${CHECKSUM_NAME}" \
        "${DSYM_NAME}" \
        "${PACKAGE_RESOLVED_NAME}" \
        "${SMOKE_LOG_NAME}" \
        "${VERIFICATION_LOG_NAME}" \
        "$(basename "${MANIFEST_PATH}")" \
        | LC_ALL=C sort
)"
ACTUAL_FILE_LIST="$(
    find "${RELEASE_DIR}" -mindepth 1 -maxdepth 1 -print \
        | sed 's#^.*/##' \
        | LC_ALL=C sort
)"
[[ "${ACTUAL_FILE_LIST}" == "${EXPECTED_FILE_LIST}" ]] || {
    echo "error: release set contains missing or unexpected files" >&2
    diff -u <(printf '%s\n' "${EXPECTED_FILE_LIST}") <(printf '%s\n' "${ACTUAL_FILE_LIST}") >&2 || true
    exit 1
}

EXPECTED_CHECKSUM_ENTRIES="$(
    printf '%s\n' \
        "${ARTIFACT_NAME}" \
        "${BUILD_LOG_NAME}" \
        "${TEST_LOG_NAME}" \
        "${TEST_RESULTS_NAME}" \
        "${DSYM_NAME}" \
        "${PACKAGE_RESOLVED_NAME}" \
        "${SMOKE_LOG_NAME}" \
        "${VERIFICATION_LOG_NAME}" \
        "$(basename "${MANIFEST_PATH}")" \
        | LC_ALL=C sort
)"
ACTUAL_CHECKSUM_ENTRIES="$(
    awk '
        NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 1 }
        { print $2 }
    ' "${RELEASE_DIR}/${CHECKSUM_NAME}" \
        | LC_ALL=C sort
)" || clio_die "checksum file has malformed entries"
[[ "${ACTUAL_CHECKSUM_ENTRIES}" == "${EXPECTED_CHECKSUM_ENTRIES}" ]] \
    || clio_die "checksum file does not cover exactly the expected release artifacts"

(
    cd "${RELEASE_DIR}"
    shasum -a 256 -c "${CHECKSUM_NAME}"
)
[[ "$(clio_sha256 "${RELEASE_DIR}/${ARTIFACT_NAME}")" == "${DMG_SHA256}" ]] \
    || clio_die "manifest DMG checksum does not match the artifact"
[[ "$(clio_sha256 "${RELEASE_DIR}/${PACKAGE_RESOLVED_NAME}")" == "${PACKAGE_RESOLVED_SHA256}" ]] \
    || clio_die "manifest Package.resolved checksum does not match the retained lockfile"
clio_require_exact_package_lock "${RELEASE_DIR}/${PACKAGE_RESOLVED_NAME}"
[[ "$(clio_resolved_revision "${RELEASE_DIR}/${PACKAGE_RESOLVED_NAME}" swift-markdown)" == "${MARKDOWN_REVISION}" ]] \
    || clio_die "retained lockfile does not match the swift-markdown manifest revision"
[[ "$(clio_resolved_revision "${RELEASE_DIR}/${PACKAGE_RESOLVED_NAME}" swift-cmark)" == "${CMARK_REVISION}" ]] \
    || clio_die "retained lockfile does not match the swift-cmark manifest revision"
for build_metadata in \
    "commit=${SOURCE_COMMIT}" \
    "sourceDateEpoch=${SOURCE_DATE_EPOCH}" \
    "version=${VERSION}" \
    "build=${BUILD}" \
    "xcode=${XCODE_VERSION}" \
    "xcodegen=${XCODEGEN_VERSION}" \
    "packageResolvedSha256=${PACKAGE_RESOLVED_SHA256}"; do
    grep -Fqx "${build_metadata}" "${RELEASE_DIR}/${BUILD_LOG_NAME}" \
        || clio_die "build log is missing recorded metadata: ${build_metadata}"
done
grep -q '^\*\* BUILD SUCCEEDED \*\*$' "${RELEASE_DIR}/${BUILD_LOG_NAME}" \
    || clio_die "build log does not contain a successful Release build"
grep -q '^\*\* TEST SUCCEEDED \*\*$' "${RELEASE_DIR}/${TEST_LOG_NAME}" \
    || clio_die "test log does not contain a successful test gate"
unzip -tq "${RELEASE_DIR}/${TEST_RESULTS_NAME}" >/dev/null \
    || clio_die "test result archive is corrupt"
TEST_RESULT_LISTING="$(zipinfo -1 "${RELEASE_DIR}/${TEST_RESULTS_NAME}")" \
    || clio_die "could not inspect the test result archive"
grep -q '^Clio-tests.xcresult/Info.plist$' <<<"${TEST_RESULT_LISTING}" \
    || clio_die "test result archive is missing its result bundle metadata"
grep -q '^Verified unsigned-internal Clio ' "${RELEASE_DIR}/${VERIFICATION_LOG_NAME}" \
    || clio_die "static-verification log is incomplete"
grep -q '^Launch smoke passed:' "${RELEASE_DIR}/${SMOKE_LOG_NAME}" \
    || clio_die "launch-smoke log is incomplete"

TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
[[ "${TEMP_ROOT}" != "/" ]] || clio_die "refusing to use the filesystem root for verification temporary files"
EXTRACT_ROOT="$(mktemp -d "${TEMP_ROOT}/clio-dsym-verify.XXXXXX")"
cleanup() {
    local exit_code=$?
    case "${EXTRACT_ROOT}" in
        "${TEMP_ROOT}"/clio-dsym-verify.*)
            rm -rf -- "${EXTRACT_ROOT}"
            ;;
        *)
            echo "warning: refusing to remove unexpected dSYM verification path ${EXTRACT_ROOT}" >&2
            ;;
    esac
    exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ZIP_LISTING="$(zipinfo -1 "${RELEASE_DIR}/${DSYM_NAME}")" \
    || clio_die "could not inspect the debug-symbol archive"
while IFS= read -r archive_entry; do
    [[ -n "${archive_entry}" ]] || clio_die "debug-symbol archive contains an empty entry name"
    [[ "${archive_entry}" != /* \
        && "${archive_entry}" != ".." \
        && "${archive_entry}" != ../* \
        && "${archive_entry}" != */../* \
        && "${archive_entry}" != */.. ]] \
        || clio_die "debug-symbol archive contains an unsafe path: ${archive_entry}"
    case "${archive_entry}" in
        Clio.app.dSYM | Clio.app.dSYM/* | __MACOSX | __MACOSX/*)
            ;;
        *)
            clio_die "debug-symbol archive contains an unexpected root: ${archive_entry}"
            ;;
    esac
done <<<"${ZIP_LISTING}"
ZIP_DETAILS="$(zipinfo -l "${RELEASE_DIR}/${DSYM_NAME}")" \
    || clio_die "could not inspect debug-symbol archive metadata"
if grep -q '^l' <<<"${ZIP_DETAILS}"; then
    clio_die "debug-symbol archive contains a symbolic link"
fi

ditto -x -k "${RELEASE_DIR}/${DSYM_NAME}" "${EXTRACT_ROOT}"
EXTRACTED_DSYM="${EXTRACT_ROOT}/Clio.app.dSYM"
[[ -d "${EXTRACTED_DSYM}" ]] || clio_die "debug-symbol archive has an unexpected layout"

CLIO_EXPECTED_BUNDLE_ID="${BUNDLE_ID}" \
CLIO_EXPECTED_VERSION="${VERSION}" \
CLIO_EXPECTED_BUILD="${BUILD}" \
    "${SCRIPT_DIR}/verify-unsigned-dmg.sh" \
        "${RELEASE_DIR}/${ARTIFACT_NAME}" \
        "${EXTRACTED_DSYM}"

echo "Verified complete release set ${RELEASE_DIR} at ${SOURCE_COMMIT}."
