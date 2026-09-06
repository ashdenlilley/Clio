#!/usr/bin/env python3
"""Xcode Cloud only: export, notarize and publish an internal tag's DMG.

No third-party Python packages. Secrets are never logged. Failed uploads are
left unpublished for diagnosis; existing releases are never overwritten.
Xcode test results are advisory, not release gates. Signing/integrity still gate.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
TEAM = os.environ.get("DEVELOPER_TEAM_ID", "")
CLOUD_TEAM = os.environ.get("EXPECTED_CLOUD_TEAM_ID", "")
REPO = "ashdenlilley/Clio"
ASC = "https://api.appstoreconnect.apple.com"
GH = "https://api.github.com"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def validate_teams(environment):
    require(bool(re.fullmatch(r"[A-Z0-9]{10}", TEAM)), "configure DEVELOPER_TEAM_ID in restricted CI settings")
    require(bool(re.fullmatch(r"[A-Fa-f0-9-]{36}", CLOUD_TEAM)), "configure EXPECTED_CLOUD_TEAM_ID in restricted CI settings")
    require(environment.get("CI_TEAM_ID") == CLOUD_TEAM, "wrong App Store Connect Cloud team")
    require(environment.get("DEVELOPER_TEAM_ID") == TEAM, "wrong Developer ID signing team")


def run(*args, input_data=None):
    # Do not include command arguments or subprocess output in exceptions: some
    # Apple tools accept passwords as arguments or may echo sensitive input.
    result = subprocess.run([str(a) for a in args], input=input_data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0, f"{Path(str(args[0])).name} failed (exit {result.returncode})")
    return result.stdout


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def raw_ecdsa(der):
    # OpenSSL emits DER SEQUENCE(INTEGER r, INTEGER s); JWT needs fixed r || s.
    require(len(der) >= 8 and der[0] == 0x30 and der[1] == len(der)-2,
            "invalid P-256 signature")
    values, offset = [], 2
    for _ in range(2):
        require(offset + 2 <= len(der) and der[offset] == 2, "invalid signature integer")
        length = der[offset+1]
        value = der[offset+2:offset+2+length].lstrip(b"\0")
        require(0 < len(value) <= 32 and offset+2+length <= len(der), "invalid signature length")
        values.append(value.rjust(32, b"\0"))
        offset += 2 + length
    require(offset == len(der), "unexpected signature data")
    return b"".join(values)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward credentials to an API-provided destination.


class API:
    def __init__(self, key):
        self.key = key
        self.opener = urllib.request.build_opener(NoRedirect)

    def jwt(self):
        now = int(time.time())
        header = b64(json.dumps({"alg": "ES256", "kid": os.environ["NOTARY_KEY_ID"],
                                 "typ": "JWT"}).encode())
        body = b64(json.dumps({"iss": os.environ["NOTARY_ISSUER_ID"], "iat": now,
                               "exp": now+300, "aud": "appstoreconnect-v1"}).encode())
        payload = header + b"." + body
        signature = run("/usr/bin/openssl", "dgst", "-sha256", "-sign", self.key,
                        input_data=payload)
        return (payload+b"."+b64(raw_ecdsa(signature))).decode()

    def request(self, url, method="GET", data=None, binary=False, missing_ok=False, timeout=120):
        parsed = urllib.parse.urlsplit(url)
        require(parsed.scheme == "https" and parsed.netloc in
                ("api.appstoreconnect.apple.com", "api.github.com", "uploads.github.com"),
                "untrusted API URL")
        apple = parsed.netloc == "api.appstoreconnect.apple.com"
        token = self.jwt() if apple else os.environ["GITHUB_TOKEN"]
        headers = {"Authorization": "Bearer "+token, "Accept": "application/json",
                   "User-Agent": "Clio-Xcode-Cloud-Release"}
        if not apple:
            headers["X-GitHub-Api-Version"] = "2022-11-28"
        payload = data if binary else (json.dumps(data).encode() if data is not None else None)
        if payload is not None:
            headers["Content-Type"] = "application/octet-stream" if binary else "application/json"
        try:
            with self.opener.open(urllib.request.Request(url, data=payload, headers=headers,
                                                        method=method), timeout=timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise RuntimeError(f"{parsed.netloc} {method} failed (HTTP {error.code}); check API permissions") from None


def advisory_test_report(api, commit):
    """A bounded, best-effort snapshot of this build, never a success attestation.

    Archive hooks can finish before sibling tests. Never wait for the containing
    build, substitute an older commit's green result, or hide unavailable data.
    """
    build_id = os.environ.get("CI_BUILD_ID", "")
    valid_id = bool(re.fullmatch(r"[A-Za-z0-9-]+", build_id))
    report = {
        "policy": "internal-advisory", "blocksRelease": False, "commit": commit,
        "cloudBuildID": build_id if valid_id else None,
        "cloudBuildURL": None,
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "testStatus": "unavailable", "actions": [],
        "note": "Packaging-time snapshot only. Final test results and notifications remain in Xcode Cloud and GitHub checks. Internal release does not certify tests passed.",
    }
    try:
        require(valid_id, "missing Cloud build metadata")
        # One bounded request; pagination/incomplete data is reported, not trusted
        # as a pass. Test reporting must not hold up signing on an API outage.
        page = api.request(f"{ASC}/v1/ciBuildRuns/{build_id}/actions?limit=100", timeout=15)
        for action in page["data"]:
            a = action.get("attributes", {})
            if a.get("actionType") not in ("TEST", "ANALYZE"):
                continue
            counts = a.get("issueCounts") or {}
            report["actions"].append({
                "type": a["actionType"],
                "progress": a.get("executionProgress"),
                "status": a.get("completionStatus"),
                "requiredToPass": a.get("isRequiredToPass"),
                "issueCounts": {k: counts.get(k, 0) for k in ("errors", "testFailures", "analyzerWarnings")},
            })
        tests = [a for a in report["actions"] if a["type"] == "TEST"]
        if any(a["status"] in ("FAILED", "ERRORED") or any(a["issueCounts"].values()) for a in tests):
            report["testStatus"] = "failed"
        elif page.get("links", {}).get("next") or not tests:
            report["testStatus"] = "unavailable"
        elif any(a["progress"] != "COMPLETE" for a in tests):
            report["testStatus"] = "pending"
        elif all(a["status"] == "SUCCEEDED" for a in tests):
            report["testStatus"] = "passed"
        else:
            report["testStatus"] = "incomplete"
    except Exception:
        # Report lookup is deliberately advisory; never echo API bodies, URLs
        # from exceptions, or credential-bearing subprocess diagnostics.
        report["testStatus"] = "unavailable"
        report["note"] += " Cloud status lookup was unavailable or incomplete."
    print(f"Internal release: Xcode test status {report['testStatus']} (advisory)", flush=True)
    return report


def verify_tag(api, tag, commit):
    ref = api.request(f"{GH}/repos/{REPO}/git/ref/tags/{tag}")["object"]
    for _ in range(5):
        if ref["type"] == "commit":
            require(ref["sha"] == commit, "GitHub tag points to another commit")
            return
        require(ref["type"] == "tag" and re.fullmatch(r"[0-9a-f]{40}", ref["sha"]), "invalid Git tag object")
        ref = api.request(f"{GH}/repos/{REPO}/git/tags/{ref['sha']}")["object"]
    raise RuntimeError("too many nested annotated tags")


def verify_app(app, version):
    info = plistlib.loads((app/"Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == "olympus.clio.mac", "wrong app bundle ID")
    require(info.get("CFBundleShortVersionString") == version, "tag version must match MARKETING_VERSION")
    require(info.get("CFBundleExecutable") == "Clio", "unexpected executable")
    require(set(run("/usr/bin/lipo", "-archs", app/"Contents/MacOS/Clio").decode().split())
            == {"arm64", "x86_64"}, "release must be universal arm64/x86_64")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    details = subprocess.run(["/usr/bin/codesign", "-dvv", str(app)], capture_output=True)
    require(details.returncode == 0, "cannot inspect signature")
    signature = details.stderr.decode()
    require(f"TeamIdentifier={TEAM}" in signature and "Authority=Developer ID Application:" in signature
            and "runtime" in signature and "Timestamp=" in signature, "invalid Developer ID/runtime/timestamp")
    entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", ":-", app))
    require(entitlements.get("com.apple.security.app-sandbox") is True, "App Sandbox missing")
    require(entitlements.get("com.apple.security.files.user-selected.read-write") is True,
            "user-selected file access missing")
    require(not entitlements.get("com.apple.security.get-task-allow"), "debug entitlement in release")
    return info


def notarize(path, key, output):
    print(f"Submitting {path.name} for notarization", flush=True)
    auth = ("--key", key, "--key-id", os.environ["NOTARY_KEY_ID"],
            "--issuer", os.environ["NOTARY_ISSUER_ID"])
    result = json.loads(run("/usr/bin/xcrun", "notarytool", "submit", path, *auth,
                            "--wait", "--timeout", "30m", "--output-format", "json"))
    (output/(path.stem+"-notary.json")).write_text(json.dumps(result, indent=2))
    submission = result.get("id", "")
    require(re.fullmatch(r"[A-Za-z0-9-]+", submission), "missing notary submission ID")
    run("/usr/bin/xcrun", "notarytool", "log", submission, *auth,
        output/(path.stem+"-notary-log.json"))
    require(result.get("status") == "Accepted", "Apple did not accept notarization")


def publish(api, tag, commit, output, report):
    base = f"{GH}/repos/{REPO}/releases"
    verify_tag(api, tag, commit)
    require(api.request(base+"/tags/"+tag, missing_ok=True) is None, "release already exists; refusing overwrite")
    for path in output.iterdir():
        require(path.is_file() and not path.is_symlink(), "unexpected release asset")
        require(path.name in public_asset_names(tag), "private or unexpected release asset; refusing upload")
    # Transactional staging only: automatically publish after every asset verifies.
    # A failure leaves a draft for diagnosis, never a public partial release.
    body = (f"Internal testing build — not a public-quality release.\n\n"
            f"Developer ID signed and notarized universal macOS DMG.\n\nSource: `{commit}`\n\n"
            f"Xcode test status at packaging: **{report['testStatus']}** (advisory, not a release gate). "
            "Failed, pending or unavailable tests do not prevent this internal cut. "
            "Signing/notarization does not establish application correctness.\n\n"
            "See ci-test-status.json and SHA256SUMS. "
            "Test results may finish after upload; the snapshot is not updated automatically.")
    release = api.request(base, "POST", {"tag_name": tag, "target_commitish": commit,
        "name": "Clio "+tag[1:]+" — Internal testing", "draft": True,
        "prerelease": True, "make_latest": "false", "body": body})
    release_id = release["id"]
    require(isinstance(release_id, int), "invalid GitHub release ID")
    print(f"Uploading verified assets to release {release_id}", flush=True)
    for path in sorted(output.iterdir()):
        require(path.is_file() and not path.is_symlink(), "unexpected release asset")
        require(path.name in public_asset_names(tag), "private or unexpected release asset; refusing upload")
        data = path.read_bytes()
        asset = api.request(f"https://uploads.github.com/repos/{REPO}/releases/{release_id}/assets?name="
                            + urllib.parse.quote(path.name), "POST", data, binary=True)
        require(asset.get("state") == "uploaded" and asset.get("size") == len(data)
                and asset.get("digest") == "sha256:"+hashlib.sha256(data).hexdigest(),
                "GitHub uploaded asset verification failed; draft retained")
    verify_tag(api, tag, commit)
    final = api.request(base+f"/{release_id}", "PATCH",
                        {"draft": False, "prerelease": True, "make_latest": "false"})
    require(final.get("draft") is False and final.get("prerelease") is True,
            "GitHub did not confirm internal prerelease publication")
    print(f"Published https://github.com/{REPO}/releases/tag/{tag}", flush=True)


def public_asset_names(tag):
    return {f"Clio-{tag[1:]}.dmg", "Clio.app.dSYM.zip", "SHA256SUMS",
            "manifest.json", "ci-test-status.json", "Package.resolved"}


def public_test_report(report):
    # Explicit projection, never serialize a full internal API response.
    return {"policy": "internal-advisory", "blocksRelease": False,
            "testStatus": report["testStatus"], "capturedAt": report.get("capturedAt"),
            "note": "Packaging-time snapshot; tests may finish later. Not an assurance of correctness."}


def main():
    e = os.environ
    require(e.get("CI_XCODE_CLOUD") == "TRUE" and e.get("CI_XCODEBUILD_ACTION") == "archive"
            and e.get("CI_XCODEBUILD_EXIT_CODE") == "0", "requires successful Cloud archive")
    validate_teams(e)
    tag, commit = e.get("CI_TAG", ""), e.get("CI_COMMIT", "")
    require(re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", tag), "invalid release tag")
    require(e.get("CI_GIT_REF") == "refs/tags/"+tag and not e.get("CI_PULL_REQUEST_NUMBER"), "not a tag build")
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "invalid commit")
    require(run("git", "-C", ROOT, "rev-parse", "HEAD").decode().strip() == commit, "checkout mismatch")
    archive = Path(e["CI_ARCHIVE_PATH"])
    require(archive.is_dir() and not archive.is_symlink(), "missing Cloud archive")
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="clio-cloud-release-") as temporary:
        work = Path(temporary)
        key, cert, keychain = work/"notary.p8", work/"identity.p12", work/"release.keychain-db"
        key.write_text(e["NOTARY_PRIVATE_KEY"])
        cert.write_bytes(base64.b64decode("".join(e["DEVELOPER_ID_CERT_P12"].split()), validate=True))
        api = API(key)
        verify_tag(api, tag, commit)
        require(api.request(f"{GH}/repos/{REPO}/releases/tags/{tag}", missing_ok=True) is None,
                "release already exists; refusing overwrite")
        print("Internal release: successful archive and exact tag verified; Xcode tests are advisory", flush=True)
        password = secrets.token_hex(32)
        old_keychains = run("/usr/bin/security", "list-keychains", "-d", "user").decode()
        import shlex
        search_list = shlex.split(old_keychains)
        created = False
        try:
            run("/usr/bin/security", "create-keychain", "-p", password, keychain)
            created = True
            run("/usr/bin/security", "set-keychain-settings", "-lut", "7200", keychain)
            run("/usr/bin/security", "unlock-keychain", "-p", password, keychain)
            run("/usr/bin/security", "import", cert, "-k", keychain, "-P", e["DEVELOPER_ID_CERT_PASSWORD"],
                "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
            run("/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                "-s", "-k", password, keychain)
            run("/usr/bin/security", "list-keychains", "-d", "user", "-s", keychain, *search_list)
            identities = run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning", keychain).decode()
            matches = re.findall(r'([0-9A-F]{40}) "Developer ID Application:[^"\n]+\('+TEAM+r'\)"', identities)
            require(len(matches) == 1, "expected exactly one valid Developer ID Application identity for Clio's team")
            identity = matches[0]
            options = work/"ExportOptions.plist"
            options.write_bytes(plistlib.dumps({"method": "developer-id", "teamID": TEAM,
                "signingStyle": "manual", "signingCertificate": identity,
                "manageAppVersionAndBuildNumber": False}))
            exported = work/"export"
            run("/usr/bin/xcodebuild", "-exportArchive", "-archivePath", archive,
                "-exportPath", exported, "-exportOptionsPlist", options)
            app = exported/"Clio.app"
            info = verify_app(app, tag[1:])
            output = work/"assets"
            output.mkdir()
            notary_records = work/"private-notary-records"
            notary_records.mkdir()
            appzip = work/"Clio-app.zip"
            run("/usr/bin/ditto", "-c", "-k", "--keepParent", app, appzip)
            notarize(appzip, key, notary_records)
            run("/usr/bin/xcrun", "stapler", "staple", app)
            run("/usr/bin/xcrun", "stapler", "validate", app)
            run("/usr/sbin/spctl", "--assess", "--type", "execute", app)
            staging = work/"dmg-root"
            staging.mkdir()
            run("/usr/bin/ditto", app, staging/"Clio.app")
            (staging/"Applications").symlink_to("/Applications")
            # DiskImages helpers need traverse permission; never expose secrets.
            work.chmod(0o711)
            staging.chmod(0o755)
            output.chmod(0o755)
            dmg = output/f"Clio-{tag[1:]}.dmg"
            run("/usr/bin/hdiutil", "create", "-volname", "Clio "+tag[1:], "-srcfolder", staging,
                "-fs", "HFS+", "-format", "UDZO", "-imagekey", "zlib-level=9", dmg)
            run("/usr/bin/codesign", "--sign", identity, "--keychain", keychain, "--timestamp", dmg)
            notarize(dmg, key, notary_records)
            run("/usr/bin/xcrun", "stapler", "staple", dmg)
            run("/usr/bin/xcrun", "stapler", "validate", dmg)
            run("/usr/bin/codesign", "--verify", "--strict", dmg)
            run("/usr/bin/hdiutil", "verify", dmg)
            run("/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg)
            mount = work/"mount"
            mount.mkdir()
            run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg)
            try:
                verify_app(mount/"Clio.app", tag[1:])
                run("/usr/bin/xcrun", "stapler", "validate", mount/"Clio.app")
                run("/usr/sbin/spctl", "--assess", "--type", "execute", mount/"Clio.app")
                require((mount/"Applications").is_symlink()
                        and os.readlink(mount/"Applications") == "/Applications", "DMG install link missing")
            finally:
                run("/usr/bin/hdiutil", "detach", mount)
            report = advisory_test_report(api, commit)
            (output/"ci-test-status.json").write_text(json.dumps(public_test_report(report), indent=2))
            manifest = {"commit": commit, "tag": tag, "bundleID": "olympus.clio.mac",
                "version": tag[1:], "build": info["CFBundleVersion"],
                "releaseChannel": "internal", "testPolicy": "advisory", "testStatus": report["testStatus"],
                "architectures": ["arm64", "x86_64"],
                "xcode": run("/usr/bin/xcodebuild", "-version").decode().strip(),
                "verification": "Developer ID, runtime, sandbox, universal, app and DMG notarization/stapling, codesign, hdiutil, mounted app, spctl",
                "limitations": "Internal testing only. Test failures do not block publication. Does not replace a fresh-download installation test on a clean supported Mac."}
            (output/"manifest.json").write_text(json.dumps(manifest, indent=2))
            lock = ROOT/"Clio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            (output/"Package.resolved").write_bytes(lock.read_bytes())
            dsym = archive/"dSYMs/Clio.app.dSYM"
            require(dsym.is_dir(), "archive dSYM missing")
            def uuids(path):
                return set(re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)",
                                      run("/usr/bin/dwarfdump", "--uuid", path).decode()))
            app_uuids, symbol_uuids = uuids(app/"Contents/MacOS/Clio"), uuids(dsym)
            require(len(app_uuids) == 2 and app_uuids == symbol_uuids, "dSYM UUIDs do not match app")
            run("/usr/bin/ditto", "-c", "-k", "--keepParent", dsym, output/"Clio.app.dSYM.zip")
            checksums = "".join(hashlib.sha256(p.read_bytes()).hexdigest()+"  "+p.name+"\n"
                                for p in sorted(output.iterdir()))
            (output/"SHA256SUMS").write_text(checksums)
        finally:
            # Best effort both operations, even when one cleanup operation fails.
            if created:
                try:
                    run("/usr/bin/security", "list-keychains", "-d", "user", "-s", *search_list)
                finally:
                    run("/usr/bin/security", "delete-keychain", keychain)
        # Cleanup is a gate too: no publication if signing-keychain cleanup fails.
        publish(api, tag, commit, output, report)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Avoid raw urllib/subprocess exceptions containing credentials or bodies.
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("Release stopped: "+message, flush=True)
        raise SystemExit(1)
