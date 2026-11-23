import importlib.util
import io
import json
import unittest
from pathlib import Path
from urllib.error import HTTPError
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "usernet_release.py"
SPEC = importlib.util.spec_from_file_location("usernet_release", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(release)


class UserNetReleaseTagTests(unittest.TestCase):
    def test_resolves_annotated_release_tag_to_commit(self):
        tag_object = "a" * 40
        commit = "b" * 40
        responses = {
            f"{release.GITHUB_API}/repos/localzet/UserNet/git/ref/tags/v0.5.13": {
                "object": {"type": "tag", "sha": tag_object},
            },
            f"{release.GITHUB_API}/repos/localzet/UserNet/git/tags/{tag_object}": {
                "object": {"type": "commit", "sha": commit},
            },
        }

        def fake_urlopen(request, timeout):
            self.assertEqual(10, timeout)
            self.assertEqual("Bearer test-token", request.get_header("Authorization"))
            return io.BytesIO(json.dumps(responses[request.full_url]).encode())

        with patch.object(release, "urlopen", side_effect=fake_urlopen):
            actual = release.resolve_tag_commit("localzet/UserNet", "v0.5.13", "test-token")
        self.assertEqual(commit, actual)

    def test_missing_tag_returns_none(self):
        def fake_urlopen(request, timeout):
            raise HTTPError(request.full_url, 404, "Not Found", None, None)

        with patch.object(release, "urlopen", side_effect=fake_urlopen):
            actual = release.resolve_tag_commit("localzet/UserNet", "v0.5.13", "test-token")
        self.assertIsNone(actual)

    def test_missing_annotated_tag_object_is_rejected(self):
        tag_object = "a" * 40

        def fake_urlopen(request, timeout):
            if "/git/ref/" in request.full_url:
                payload = {"object": {"type": "tag", "sha": tag_object}}
                return io.BytesIO(json.dumps(payload).encode())
            raise HTTPError(request.full_url, 404, "Not Found", None, None)

        with patch.object(release, "urlopen", side_effect=fake_urlopen):
            with self.assertRaisesRegex(release.ReleaseTagError, "HTTP 404"):
                release.resolve_tag_commit("localzet/UserNet", "v0.5.13", "test-token")

    def test_rejects_invalid_tag_target_and_bad_input(self):
        def fake_urlopen(request, timeout):
            payload = {"object": {"type": "tree", "sha": "a" * 40}}
            return io.BytesIO(json.dumps(payload).encode())

        with patch.object(release, "urlopen", side_effect=fake_urlopen):
            with self.assertRaisesRegex(release.ReleaseTagError, "does not resolve"):
                release.resolve_tag_commit("localzet/UserNet", "v0.5.13", "test-token")
        with self.assertRaisesRegex(release.ReleaseTagError, "Invalid repository or release tag"):
            release.resolve_tag_commit("localzet/UserNet/extra", "v0.5.13", "test-token")

    def test_tag_target_validation_covers_new_release_resume_and_finalize(self):
        source_commit = "a" * 40
        old_commit = "b" * 40

        release.validate_tag_target(None, source_commit, 2026112201, 2026110805, False)
        release.validate_tag_target("", source_commit, 2026112201, 2026110805, False)
        release.validate_tag_target(source_commit, source_commit, 2026112201, 2026110805, True)
        release.validate_tag_target(old_commit, source_commit, 2026110805, 2026110805, True)

        with self.assertRaisesRegex(release.ReleaseTagError, "different source commit"):
            release.validate_tag_target(old_commit, source_commit, 2026112201, 2026110805, True)
        with self.assertRaisesRegex(release.ReleaseTagError, "without its Git tag"):
            release.validate_tag_target(None, source_commit, 2026110805, 2026110805, True)


if __name__ == "__main__":
    unittest.main()
