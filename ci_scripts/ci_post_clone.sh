#!/bin/bash
# No secret values are printed. This hook validates inputs; it never publishes.
set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
source "${ROOT}/scripts/release-common.sh"
source "${ROOT}/scripts/cloud-release-preflight.sh"

# Account-specific expectations are supplied through restricted CI settings.
# Release-tag validation below fails closed if that configuration is missing.
[[ "${CI_XCODE_CLOUD:-}" == "TRUE" ]] || clio_die "this hook requires Xcode Cloud"
# Generate matching macOS fallback sizes on the Cloud runtime before compiling.
# The layered Icon Composer source remains authoritative for modern appearances.
CLIO_ICON_XCODE_APP="${DEVELOPER_DIR%/Contents/Developer}" bash "${ROOT}/scripts/update-app-icon.sh"
clio_require_exact_package_lock "${ROOT}/Clio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
bash "${ROOT}/scripts/test-cloud-release-preflight.sh"
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "${ROOT}/scripts/test_cloud_release.py"

if clio_is_release_tag; then
    clio_validate_release_environment
    clio_validate_release_checkout "${ROOT}"
    echo "Clio internal release input preflight passed; Xcode tests are advisory. Archive, signing and artifact verification remain required."
else
    echo "Clio CI dependency preflight passed; this is not a release tag."
fi
