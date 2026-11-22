import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "verify_usernet_apk.py"
SPEC = importlib.util.spec_from_file_location("verify_usernet_apk", SCRIPT)
signing = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(signing)


class UserNetSigningTests(unittest.TestCase):
    def test_extracts_legacy_and_versioned_apksigner_formats(self):
        fingerprint = signing.EXPECTED_STABLE_SIGNER_SHA256
        self.assertEqual(
            fingerprint,
            signing.extract_signer_sha256(
                f"Signer #1 certificate SHA-256 digest: {fingerprint.upper()}"
            ),
        )
        self.assertEqual(
            fingerprint,
            signing.extract_signer_sha256(
                f"V2 Signer: certificate SHA-256 digest: {fingerprint}"
            ),
        )
        self.assertEqual(
            fingerprint,
            signing.extract_signer_sha256(
                f"V3.0 Signer: certificate SHA-256 digest: {fingerprint}"
            ),
        )

    def test_rejects_missing_or_multiple_signers(self):
        with self.assertRaises(ValueError):
            signing.extract_signer_sha256("APK verified without signer output")

        fingerprint = signing.EXPECTED_STABLE_SIGNER_SHA256
        output = (
            f"Signer #1 certificate SHA-256 digest: {fingerprint}\n"
            f"Signer #2 certificate SHA-256 digest: {fingerprint}"
        )
        with self.assertRaises(ValueError):
            signing.extract_signer_sha256(output)

    @patch.object(signing.subprocess, "run")
    def test_rejects_an_unexpected_signer(self, run):
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="Signer #1 certificate SHA-256 digest: " + "0" * 64,
            stderr="",
        )
        with self.assertRaisesRegex(RuntimeError, "published identity"):
            signing.verify_stable_apk(Path("apksigner"), Path("release.apk"))

    @patch.object(signing.subprocess, "run")
    def test_rejects_invalid_signature(self, run):
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="signature invalid"
        )
        with self.assertRaisesRegex(RuntimeError, "signature verification"):
            signing.verify_stable_apk(Path("apksigner"), Path("release.apk"))


if __name__ == "__main__":
    unittest.main()
