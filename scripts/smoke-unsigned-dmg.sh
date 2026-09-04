#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=release-common.sh
source "${SCRIPT_DIR}/release-common.sh"

DMG_PATH="${1:-}"
EXTERNAL_LOG_PATH="${2:-}"
EXPECTED_BUNDLE_ID="${CLIO_EXPECTED_BUNDLE_ID:-olympus.clio.mac}"
EXPECTED_VERSION="${CLIO_EXPECTED_VERSION:-0.1.0}"
EXPECTED_BUILD="${CLIO_EXPECTED_BUILD:-1}"
RUN_SECONDS="${CLIO_SMOKE_SECONDS:-5}"

if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
    echo "usage: $0 /absolute/path/to/Clio-<version>-unsigned.dmg [diagnostic-log]" >&2
    exit 64
fi
[[ "${RUN_SECONDS}" =~ ^[1-9][0-9]*$ ]] || clio_die "CLIO_SMOKE_SECONDS must be a positive integer"
[[ "${RUN_SECONDS}" -le 60 ]] || clio_die "CLIO_SMOKE_SECONDS must not exceed 60"
[[ "${EXPECTED_BUNDLE_ID}" == "olympus.clio.mac" ]] \
    || clio_die "the release smoke only permits bundle identifier olympus.clio.mac"

for command_name in defaults ditto hdiutil sandbox-exec uuidgen; do
    clio_require_command "${command_name}"
done

DMG_PATH="$(cd "$(dirname "${DMG_PATH}")" && pwd -P)/$(basename "${DMG_PATH}")"
if [[ -n "${EXTERNAL_LOG_PATH}" ]]; then
    mkdir -p "$(dirname "${EXTERNAL_LOG_PATH}")"
    EXTERNAL_LOG_PATH="$(cd "$(dirname "${EXTERNAL_LOG_PATH}")" && pwd -P)/$(basename "${EXTERNAL_LOG_PATH}")"
    [[ ! -e "${EXTERNAL_LOG_PATH}" && ! -L "${EXTERNAL_LOG_PATH}" ]] \
        || clio_die "refusing to replace an existing launch-smoke log: ${EXTERNAL_LOG_PATH}"
fi

# Verify the static artifact before executing anything from it.
CLIO_EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID}" \
CLIO_EXPECTED_VERSION="${EXPECTED_VERSION}" \
CLIO_EXPECTED_BUILD="${EXPECTED_BUILD}" \
    "${SCRIPT_DIR}/verify-unsigned-dmg.sh" "${DMG_PATH}"

TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
[[ "${TEMP_ROOT}" != "/" ]] || clio_die "refusing to use the filesystem root for smoke temporary files"
WORK_ROOT="$(mktemp -d "${TEMP_ROOT}/clio-launch-smoke.XXXXXX")"
MOUNT_DIR="${WORK_ROOT}/mount"
COPY_DIR="${WORK_ROOT}/copy"
ISOLATED_HOME="${WORK_ROOT}/home"
ISOLATED_TMP="${WORK_ROOT}/tmp"
SANDBOX_PROFILE="${WORK_ROOT}/launch.sb"
INTERNAL_LOG_PATH="${WORK_ROOT}/launch.log"
mkdir -p \
    "${MOUNT_DIR}" \
    "${COPY_DIR}" \
    "${ISOLATED_HOME}/Documents" \
    "${ISOLATED_HOME}/Library/Application Support" \
    "${ISOLATED_TMP}"

ATTACHED=0
APP_PID=""
SMOKE_BUNDLE_ID=""
SAVED_STATE_PATH=""
SUCCEEDED=0

cleanup() {
    local exit_code=$?

    if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" >/dev/null 2>&1; then
        kill -TERM "${APP_PID}" >/dev/null 2>&1 || true
        sleep 1
        if kill -0 "${APP_PID}" >/dev/null 2>&1; then
            kill -KILL "${APP_PID}" >/dev/null 2>&1 || true
        fi
        wait "${APP_PID}" 2>/dev/null || true
    fi
    if [[ "${ATTACHED}" -eq 1 ]]; then
        clio_detach_mount "${MOUNT_DIR}" || true
    fi
    if [[ -n "${SMOKE_BUNDLE_ID}" ]]; then
        CFFIXED_USER_HOME="${ISOLATED_HOME}" \
            defaults delete "${SMOKE_BUNDLE_ID}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${SAVED_STATE_PATH}" && ( -e "${SAVED_STATE_PATH}" || -L "${SAVED_STATE_PATH}" ) ]]; then
        case "${SAVED_STATE_PATH}" in
            "${TEMP_ROOT}/${EXPECTED_BUNDLE_ID}.release-smoke.smoke"*.savedState)
                rm -rf -- "${SAVED_STATE_PATH}"
                ;;
            *)
                echo "warning: refusing to remove unexpected saved-state path ${SAVED_STATE_PATH}" >&2
                ;;
        esac
    fi

    if [[ -n "${EXTERNAL_LOG_PATH}" && -f "${INTERNAL_LOG_PATH}" ]]; then
        ditto "${INTERNAL_LOG_PATH}" "${EXTERNAL_LOG_PATH}" >/dev/null 2>&1 || true
    fi

    if [[ "${SUCCEEDED}" -eq 1 ]]; then
        case "${WORK_ROOT}" in
            "${TEMP_ROOT}"/clio-launch-smoke.*)
                rm -rf -- "${WORK_ROOT}"
                ;;
            *)
                echo "warning: refusing to remove unexpected smoke path ${WORK_ROOT}" >&2
                ;;
        esac
    else
        echo "Launch-smoke diagnostics retained at ${WORK_ROOT}" >&2
    fi

    exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

hdiutil attach "${DMG_PATH}" -readonly -nobrowse -mountpoint "${MOUNT_DIR}" -quiet
ATTACHED=1

SOURCE_APP="${MOUNT_DIR}/Clio.app"
SMOKE_APP="${COPY_DIR}/Clio Release Smoke.app"
ditto "${SOURCE_APP}" "${SMOKE_APP}"

# No production launch-argument seam exists for replacing AppState's file roots.
# A one-time bundle ID isolates preferences/restoration, while CFFIXED_USER_HOME
# redirects Documents and Application Support into this disposable directory.
# The outer Seatbelt profile is defense in depth: even if redirection regresses,
# this process cannot write to /Users, /Volumes, or /Applications.
SMOKE_SUFFIX="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
SMOKE_BUNDLE_ID="${EXPECTED_BUNDLE_ID}.release-smoke.smoke${SMOKE_SUFFIX}"
SAVED_STATE_PATH="${TEMP_ROOT}/${SMOKE_BUNDLE_ID}.savedState"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${SMOKE_BUNDLE_ID}" \
    "${SMOKE_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Clio Release Smoke' \
    "${SMOKE_APP}/Contents/Info.plist"

cat >"${SANDBOX_PROFILE}" <<'PROFILE'
(version 1)
(allow default)
(deny file-write* (subpath "/Applications"))
(deny file-write* (subpath "/Users"))
(deny file-write* (subpath "/Volumes"))
(deny file-write* (subpath "/System/Volumes/Data/Applications"))
(deny file-write* (subpath "/System/Volumes/Data/Users"))
PROFILE

SMOKE_EXECUTABLE="${SMOKE_APP}/Contents/MacOS/Clio"
{
    echo "Clio unsigned-internal process-launch smoke"
    echo "source=${DMG_PATH}"
    echo "copy=${SMOKE_APP}"
    echo "isolatedBundleIdentifier=${SMOKE_BUNDLE_ID}"
    echo "durationSeconds=${RUN_SECONDS}"
    echo "warning=This is not a Gatekeeper, notarization, Hardened Runtime, or App Sandbox test."
} >"${INTERNAL_LOG_PATH}"

sandbox-exec -f "${SANDBOX_PROFILE}" \
    /usr/bin/env \
        CFFIXED_USER_HOME="${ISOLATED_HOME}" \
        CFPREFERENCES_AVOID_DAEMON=1 \
        LLVM_PROFILE_FILE="${ISOLATED_TMP}/Clio-%p.profraw" \
        TMPDIR="${ISOLATED_TMP}/" \
        "${SMOKE_EXECUTABLE}" \
        -ApplePersistenceIgnoreState YES \
        >>"${INTERNAL_LOG_PATH}" 2>&1 &
APP_PID=$!

SECOND=0
while [[ "${SECOND}" -lt "${RUN_SECONDS}" ]]; do
    sleep 1
    if ! kill -0 "${APP_PID}" >/dev/null 2>&1; then
        set +e
        wait "${APP_PID}"
        PROCESS_STATUS=$?
        set -e
        APP_PID=""
        echo "error: Clio exited before ${RUN_SECONDS}s (status ${PROCESS_STATUS})" >&2
        tail -80 "${INTERNAL_LOG_PATH}" >&2
        exit 1
    fi
    SECOND=$((SECOND + 1))
done

kill -TERM "${APP_PID}"
SHUTDOWN_SECOND=0
while kill -0 "${APP_PID}" >/dev/null 2>&1 && [[ "${SHUTDOWN_SECOND}" -lt 3 ]]; do
    sleep 1
    SHUTDOWN_SECOND=$((SHUTDOWN_SECOND + 1))
done
if kill -0 "${APP_PID}" >/dev/null 2>&1; then
    kill -KILL "${APP_PID}" >/dev/null 2>&1 || true
fi
set +e
wait "${APP_PID}"
set -e
APP_PID=""

clio_detach_mount "${MOUNT_DIR}"
ATTACHED=0

echo "Launch smoke passed: the isolated temporary copy remained alive for ${RUN_SECONDS}s." \
    | tee -a "${INTERNAL_LOG_PATH}"
echo "This deliberately does not claim Gatekeeper, notarization, Hardened Runtime, or App Sandbox acceptance." \
    | tee -a "${INTERNAL_LOG_PATH}"
SUCCEEDED=1
