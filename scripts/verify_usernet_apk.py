#!/usr/bin/env python3
"""Verify a stable APK keeps the published UserNet signing identity."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


EXPECTED_STABLE_SIGNER_SHA256 = (
    "c8b2fa26539ab0416f13e83a16f6379222c8ca5dab2fddf338730cd2ac2201ab"
)
SIGNER_DIGEST = re.compile(
    r"^\s*(?:V\d+(?:\.\d+)?\s+)?Signer(?:\s+#\d+)?\s*:?\s*"
    r"certificate SHA-256 digest:\s*([a-fA-F0-9]{64})\s*$",
    re.IGNORECASE,
)


def extract_signer_sha256(output: str) -> str:
    fingerprints = [
        match.group(1).lower()
        for line in output.splitlines()
        if (match := SIGNER_DIGEST.match(line))
    ]
    if len(fingerprints) != 1:
        raise ValueError("Expected exactly one APK signer SHA-256 fingerprint.")
    return fingerprints[0]


def verify_stable_apk(apksigner: Path, apk: Path) -> None:
    result = subprocess.run(
        [str(apksigner), "verify", "--verbose", "--print-certs", str(apk)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError("APK signature verification failed.")

    actual = extract_signer_sha256(f"{result.stdout}\n{result.stderr}")
    if actual != EXPECTED_STABLE_SIGNER_SHA256:
        raise RuntimeError("Stable APK signer does not match the published identity.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apksigner", required=True, type=Path)
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()

    try:
        verify_stable_apk(args.apksigner, args.apk)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"UserNet APK verification failed: {error}", file=sys.stderr)
        return 1

    print("APK signature and published UserNet signer verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
