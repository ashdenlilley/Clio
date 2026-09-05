#!/bin/bash
# Side-effect-free release input checks, compatible with macOS Bash 3.2.
# Callers source release-common.sh first and must disable shell tracing.

clio_is_release_tag() {
    [[ -z "${CI_PULL_REQUEST_NUMBER:-}" ]] || return 1
    [[ -n "${CI_TAG:-}" ]] || return 1
    [[ "${CI_TAG}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
        || clio_die "release tags must use vMAJOR.MINOR.PATCH without leading zeroes"
    [[ "${CI_GIT_REF:-}" == "refs/tags/${CI_TAG}" ]] \
        || clio_die "release tag does not match the canonical Git ref"
    return 0
}

clio_validate_release_environment() {
    local variable_name
    for variable_name in DEVELOPER_ID_CERT_P12 DEVELOPER_ID_CERT_PASSWORD \
        DEVELOPER_TEAM_ID NOTARY_ISSUER_ID NOTARY_KEY_ID NOTARY_PRIVATE_KEY GITHUB_TOKEN; do
        [[ -n "${!variable_name:-}" ]] || clio_die "missing release variable: ${variable_name}"
    done
    [[ "${DEVELOPER_TEAM_ID}" == "REDACTED00" ]] || clio_die "unexpected release signing team"
    [[ "${CI_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || clio_die "invalid CI_COMMIT"
    # This validates encoding only, not the certificate identity or password.
    printf '%s' "${DEVELOPER_ID_CERT_P12}" | /usr/bin/base64 -D >/dev/null 2>&1 \
        || clio_die "DEVELOPER_ID_CERT_P12 must contain Base64-encoded PKCS#12 data"
    [[ "${NOTARY_PRIVATE_KEY}" == *"-----BEGIN PRIVATE KEY-----"* \
        && "${NOTARY_PRIVATE_KEY}" == *"-----END PRIVATE KEY-----"* ]] \
        || clio_die "NOTARY_PRIVATE_KEY must contain raw PEM .p8 text"
}
