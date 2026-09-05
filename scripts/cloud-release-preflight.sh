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

clio_validate_release_checkout() {
    local repository_path="$1"
    local checkout_commit local_tag_commit
    checkout_commit="$(git -C "${repository_path}" rev-parse --verify HEAD 2>/dev/null)" \
        || clio_die "cannot resolve release checkout HEAD"
    [[ "${checkout_commit}" == "${CI_COMMIT}" ]] \
        || clio_die "release checkout does not match CI_COMMIT"

    # Cloud can supply a detached checkout without the triggering tag ref.
    # A present tag must still match. An absent tag is NOT proof of provenance:
    # cloud-release.py always verifies the remote GitHub tag before importing
    # signing credentials, then again before creating/publishing the release.
    if git -C "${repository_path}" show-ref --verify --quiet "refs/tags/${CI_TAG}"; then
        local_tag_commit="$(git -C "${repository_path}" rev-parse --verify "refs/tags/${CI_TAG}^{commit}" 2>/dev/null)" \
            || clio_die "local release tag does not resolve to a commit"
        [[ "${local_tag_commit}" == "${CI_COMMIT}" ]] \
            || clio_die "local release tag does not match CI_COMMIT"
    else
        echo "Cloud checkout has no local tag ref; remote GitHub tag verification remains mandatory before signing/publication."
    fi
}
