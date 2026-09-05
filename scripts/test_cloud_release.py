"""Offline tests: no Apple/GitHub credentials or external writes."""
import contextlib
import io
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("cloud-release.py"))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def actions():
    return [{"attributes": {"actionType": kind, "executionProgress": "COMPLETE",
        "completionStatus": "SUCCEEDED", "isRequiredToPass": True,
        "issueCounts": {"errors": 0, "testFailures": 0, "analyzerWarnings": 0}}}
        for kind in ("TEST", "ANALYZE", "ARCHIVE")]


class Gates(unittest.TestCase):
    def test_distinct_cloud_and_signing_teams(self):
        r.validate_teams({"CI_TEAM_ID": r.CLOUD_TEAM, "DEVELOPER_TEAM_ID": r.TEAM})

    def test_swapped_or_missing_teams_rejected(self):
        for environment in ({}, {"CI_TEAM_ID": r.TEAM, "DEVELOPER_TEAM_ID": r.TEAM},
                            {"CI_TEAM_ID": r.CLOUD_TEAM, "DEVELOPER_TEAM_ID": r.CLOUD_TEAM},
                            {"CI_TEAM_ID": "another-team", "DEVELOPER_TEAM_ID": r.TEAM}):
            with self.assertRaises(RuntimeError):
                r.validate_teams(environment)

    def test_der_conversion(self):
        der = bytes([0x30, 68, 2, 32])+b"a"*32+bytes([2, 32])+b"b"*32
        self.assertEqual(r.raw_ecdsa(der), b"a"*32+b"b"*32)
        with self.assertRaises(RuntimeError):
            r.raw_ecdsa(b"bad")

    def test_untrusted_url(self):
        with self.assertRaises(RuntimeError):
            r.API(Path("unused")).request("https://example.com/steal")

    def test_tag_mismatch(self):
        class Fake:
            def request(self, url):
                return {"object": {"type": "commit", "sha": "b"*40}}
        with self.assertRaises(RuntimeError):
            r.verify_tag(Fake(), "v0.1.0", "a"*40)

    def test_publication_is_automatic_but_only_after_verified_uploads(self):
        import hashlib
        class Fake:
            def __init__(self, bad=False):
                self.calls, self.bad = [], bad
            def request(self, url, method="GET", data=None, **kwargs):
                self.calls.append((url, method, data))
                if "/git/ref/" in url:
                    return {"object": {"type": "commit", "sha": "a"*40}}
                if kwargs.get("missing_ok"):
                    return None
                if method == "PATCH":
                    return {"draft": False, "prerelease": True}
                if "uploads.github.com" in url:
                    return {"state": "uploaded", "size": len(data),
                            "digest": "bad" if self.bad else "sha256:"+hashlib.sha256(data).hexdigest()}
                return {"id": 42}
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder/"fixture.txt").write_text("fixture")
            for status in ("passed", "failed", "pending", "unavailable", "incomplete"):
                api = Fake()
                with contextlib.redirect_stdout(io.StringIO()):
                    r.publish(api, "v0.1.0", "a"*40, folder, {"testStatus": status})
                self.assertEqual(api.calls[-1][1:],
                                 ("PATCH", {"draft": False, "prerelease": True, "make_latest": "false"}))
                creation = next(c[2] for c in api.calls if c[1] == "POST" and c[0].endswith("/releases"))
                self.assertTrue(creation["prerelease"])
                self.assertTrue(creation["draft"])
                self.assertEqual(creation["make_latest"], "false")
                self.assertIn("Internal testing", creation["name"])
                self.assertIn(f"**{status}**", creation["body"])
            bad = Fake(True)
            with self.assertRaises(RuntimeError), contextlib.redirect_stdout(io.StringIO()):
                r.publish(bad, "v0.1.0", "a"*40, folder, {"testStatus": "failed"})
            self.assertFalse(any(c[1] == "PATCH" for c in bad.calls))

    def test_existing_release_never_overwritten(self):
        class Fake:
            def request(self, url, method="GET", **kwargs):
                if "/git/ref/" in url:
                    return {"object": {"type": "commit", "sha": "a"*40}}
                if kwargs.get("missing_ok"):
                    return {"id": 42}
                raise AssertionError("No writes allowed")
        with self.assertRaisesRegex(RuntimeError, "release already exists"):
            r.publish(Fake(), "v0.1.0", "a"*40, Path("unused"), {"testStatus": "failed"})

    def test_local_execution_refused(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(RuntimeError):
                r.main()

    def test_failed_archive_still_blocks(self):
        with patch.dict(os.environ, {"CI_XCODE_CLOUD": "TRUE", "CI_XCODEBUILD_ACTION": "archive",
                                     "CI_XCODEBUILD_EXIT_CODE": "65"}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "requires successful Cloud archive"):
                r.main()


class AdvisoryResults(unittest.TestCase):
    def report(self, action_list=None, page=None, error=None):
        calls = []
        class Fake:
            def request(self, url, **kwargs):
                calls.append((url, kwargs))
                if error:
                    raise error
                return page if page is not None else {"data": actions() if action_list is None else action_list}
        with patch.dict(os.environ, {"CI_BUILD_ID": "current"}, clear=True), contextlib.redirect_stdout(io.StringIO()):
            report = r.advisory_test_report(Fake(), "a"*40)
        self.assertEqual(calls, [(r.ASC+"/v1/ciBuildRuns/current/actions?limit=100", {"timeout": 15})])
        self.assertFalse(report["blocksRelease"])
        self.assertEqual(report["commit"], "a"*40)
        self.assertEqual(report["cloudBuildID"], "current")
        return report

    def test_success_is_only_advisory(self):
        report = self.report()
        self.assertEqual(report["testStatus"], "passed")
        self.assertEqual(report["policy"], "internal-advisory")

    def test_test_failure_reported_without_gate(self):
        a = actions()
        a[0]["attributes"]["completionStatus"] = "FAILED"
        a[0]["attributes"]["issueCounts"]["testFailures"] = 13
        report = self.report(a)
        self.assertEqual(report["testStatus"], "failed")
        self.assertEqual(report["actions"][0]["issueCounts"]["testFailures"], 13)

    def test_pending_results_never_claim_success(self):
        for progress in ("PENDING", "RUNNING", None):
            a = actions()
            a[0]["attributes"]["executionProgress"] = progress
            a[0]["attributes"]["completionStatus"] = None
            self.assertEqual(self.report(a)["testStatus"], "pending")

    def test_missing_and_partial_results_never_claim_success(self):
        self.assertEqual(self.report([])["testStatus"], "unavailable")
        self.assertEqual(self.report(actions()[1:])["testStatus"], "unavailable")
        self.assertEqual(self.report(page={"data": actions(), "links": {"next": "next-page"}})["testStatus"], "unavailable")

    def test_api_errors_and_malformed_responses_do_not_gate(self):
        report = self.report(error=RuntimeError("secret-body-must-not-escape"))
        self.assertEqual(report["testStatus"], "unavailable")
        self.assertNotIn("secret-body", str(report))
        self.assertEqual(self.report(page={"invalid": []})["testStatus"], "unavailable")

    def test_nonrequired_tests_are_reported_normally(self):
        a = actions()
        a[0]["attributes"]["isRequiredToPass"] = False
        self.assertEqual(self.report(a)["testStatus"], "passed")

    def test_all_test_actions_must_pass_to_report_passed(self):
        a = actions()+actions()[:1]
        a[-1]["attributes"]["completionStatus"] = "FAILED"
        self.assertEqual(self.report(a)["testStatus"], "failed")

    def test_analysis_issues_are_preserved_without_changing_test_outcome(self):
        a = actions()
        a[1]["attributes"]["completionStatus"] = "FAILED"
        a[1]["attributes"]["issueCounts"]["analyzerWarnings"] = 2
        report = self.report(a)
        self.assertEqual(report["testStatus"], "passed")
        self.assertEqual(report["actions"][1]["issueCounts"]["analyzerWarnings"], 2)

    def test_canceled_tests_are_not_reported_as_passed(self):
        a = actions()
        a[0]["attributes"]["completionStatus"] = "CANCELED"
        self.assertEqual(self.report(a)["testStatus"], "incomplete")

    def test_missing_build_metadata_is_advisory_without_network(self):
        class Fake:
            def request(self, *args, **kwargs):
                raise AssertionError("No network with missing metadata")
        with patch.dict(os.environ, {}, clear=True), contextlib.redirect_stdout(io.StringIO()):
            report = r.advisory_test_report(Fake(), "a"*40)
        self.assertEqual(report["testStatus"], "unavailable")
        self.assertIsNone(report["cloudBuildURL"])


class PostActionHook(unittest.TestCase):
    def hook(self, action, code, cloud="TRUE"):
        # Mirror a test worker that has the hook but no repository/scripts tree.
        with tempfile.TemporaryDirectory() as directory:
            hook = Path(directory)/"ci_post_xcodebuild.sh"
            shutil.copyfile(r.ROOT/"ci_scripts/ci_post_xcodebuild.sh", hook)
            return subprocess.run(["/bin/bash", str(hook)], capture_output=True, text=True,
                                  env={"PATH": "/usr/bin:/bin", "CI_XCODE_CLOUD": cloud,
                                       "CI_XCODEBUILD_ACTION": action, "CI_XCODEBUILD_EXIT_CODE": code})

    def test_failed_test_does_not_add_script_failure_or_require_checkout(self):
        result = self.hook("test", "65")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning:", result.stdout)
        self.assertIn("advisory", result.stdout)

    def test_successful_branch_archive_does_not_publish(self):
        self.assertEqual(self.hook("archive", "0").returncode, 0)

    def test_failed_archive_hook_still_fails(self):
        self.assertNotEqual(self.hook("archive", "65").returncode, 0)

    def test_build_for_testing_and_analysis_do_not_require_release_scripts(self):
        for action in ("build-for-testing", "analyze"):
            for code in ("0", "65"):
                self.assertEqual(self.hook(action, code).returncode, 0)

    def test_hook_refuses_local_execution(self):
        self.assertNotEqual(self.hook("archive", "0", cloud="FALSE").returncode, 0)


if __name__ == "__main__":
    unittest.main()
