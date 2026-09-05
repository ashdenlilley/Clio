#!/bin/bash
set +x
set -euo pipefail
# Cloud test-without-building workers may receive only ci_scripts, not the
# source checkout. Decide whether release tooling is needed before sourcing it.
[[ "${CI_XCODE_CLOUD:-}" == "TRUE" ]] || { echo "error: requires Xcode Cloud" >&2; exit 1; }
if [[ "${CI_XCODEBUILD_ACTION:-}" == "test-without-building" ]]; then
    # This worker may not have the source checkout. Keep diagnostics standalone.
    echo "Clio UI launch-stage diagnostics (no document contents or secrets):"
    /usr/bin/log show --style compact --last 30m \
        --predicate 'subsystem == "olympus.clio.mac.launch"' --info 2>/dev/null \
        || echo "Launch-stage log unavailable on this worker; inspect XCTest attachments."
fi
if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
    # The original Xcode action retains its actual result. Do not add a second
    # failed custom-script error or require release tooling on test workers.
    if [[ "${CI_XCODEBUILD_EXIT_CODE:-1}" != "0" ]]; then
        echo "warning: Xcode action reported errors; results are advisory for internal DMG releases. Inspect this action's tests/logs."
    fi
    exit 0
fi
if [[ "${CI_XCODEBUILD_EXIT_CODE:-1}" != "0" ]]; then
    echo "Xcode action failed; release processing will not run." >&2
    exit 1
fi
[[ -n "${CI_TAG:-}" && -z "${CI_PULL_REQUEST_NUMBER:-}" ]] || exit 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/scripts/release-common.sh"
source "${ROOT}/scripts/cloud-release-preflight.sh"
clio_is_release_tag || exit 0
clio_validate_release_environment
exec /usr/bin/python3 "${ROOT}/scripts/cloud-release.py"
