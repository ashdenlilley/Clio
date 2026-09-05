"""Offline tests: no Apple/GitHub credentials or external writes."""
import contextlib
import io
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("cloud-release.py"))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def build():
    return {"id": "previous", "attributes": {"executionProgress": "COMPLETE",
        "completionStatus": "SUCCEEDED", "isPullRequestBuild": False,
        "sourceCommit": {"commitSha": "a"*40}}}


def actions():
    return [{"attributes": {"actionType": kind, "executionProgress": "COMPLETE",
        "completionStatus": "SUCCEEDED", "isRequiredToPass": True,
        "issueCounts": {"errors": 0, "testFailures": 0, "analyzerWarnings": 0}}}
        for kind in ("TEST", "ANALYZE", "ARCHIVE")]


class Gates(unittest.TestCase):
    def test_success(self):
        self.assertTrue(r.successful_run(build(), "a"*40, "current"))
        self.assertTrue(r.valid_actions(actions()))

    def test_wrong_commit(self):
        self.assertFalse(r.successful_run(build(), "b"*40, "current"))

    def test_current_run_cannot_attest_itself(self):
        self.assertFalse(r.successful_run(build(), "a"*40, "previous"))

    def test_pr_and_missing_provenance(self):
        for value in (True, None):
            b = build()
            b["attributes"]["isPullRequestBuild"] = value
            self.assertFalse(r.successful_run(b, "a"*40, "current"))

    def test_incomplete_or_failed_build(self):
        for key, value in (("executionProgress", "RUNNING"), ("completionStatus", "FAILED")):
            b = build()
            b["attributes"][key] = value
            self.assertFalse(r.successful_run(b, "a"*40, "current"))

    def test_missing_actions(self):
        for value in ([], actions()[:1], actions()[1:]):
            self.assertFalse(r.valid_actions(value))

    def test_nonrequired_test(self):
        a = actions()
        a[0]["attributes"]["isRequiredToPass"] = False
        self.assertFalse(r.valid_actions(a))

    def test_each_failure_blocks(self):
        for i in range(3):
            a = actions()
            a[i]["attributes"]["completionStatus"] = "FAILED"
            self.assertFalse(r.valid_actions(a))

    def test_pending_blocks(self):
        a = actions()
        a[1]["attributes"]["executionProgress"] = "PENDING"
        self.assertFalse(r.valid_actions(a))

    def test_issues_block(self):
        for kind in ("errors", "testFailures", "analyzerWarnings"):
            a = actions()
            a[0]["attributes"]["issueCounts"][kind] = 1
            self.assertFalse(r.valid_actions(a))

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

    def test_no_ci_evidence(self):
        class Fake:
            def apple_pages(self, url):
                return iter([])
        with patch.dict(os.environ, {"CI_WORKFLOW_ID": "workflow", "CI_BUILD_ID": "current"}):
            with self.assertRaises(RuntimeError):
                r.evidence(Fake(), "a"*40)

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
                    return {"draft": False}
                if "uploads.github.com" in url:
                    return {"state": "uploaded", "size": len(data),
                            "digest": "bad" if self.bad else "sha256:"+hashlib.sha256(data).hexdigest()}
                return {"id": 42}
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder/"fixture.txt").write_text("fixture")
            api = Fake()
            with contextlib.redirect_stdout(io.StringIO()):
                r.publish(api, "v0.1.0", "a"*40, folder)
            self.assertEqual(api.calls[-1][1:], ("PATCH", {"draft": False}))
            bad = Fake(True)
            with self.assertRaises(RuntimeError), contextlib.redirect_stdout(io.StringIO()):
                r.publish(bad, "v0.1.0", "a"*40, folder)
            self.assertFalse(any(c[1] == "PATCH" for c in bad.calls))

    def test_local_execution_refused(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(RuntimeError):
                r.main()


if __name__ == "__main__":
    unittest.main()
