import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "usernet_ota.py"
SPEC = importlib.util.spec_from_file_location("usernet_ota", SCRIPT)
ota = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(ota)


class UserNetOtaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.inputs = {}
        for key in ("android", "linux", "windows", "macos-arm64", "macos-amd64"):
            source = self.root / f"source-{key}"
            source.write_bytes(f"test artifact {key}".encode())
            self.inputs[key] = source

    def tearDown(self):
        self.temporary.cleanup()

    def prepare(self, name="bundle", build=2026112201):
        output = self.root / name
        archive, assets = ota.prepare_bundle(
            version="0.5.13",
            build=build,
            notes="Release notes",
            inputs=self.inputs,
            output=output,
        )
        return output / "bundle", archive, assets

    def test_prepare_verify_and_publish_is_idempotent(self):
        bundle, archive, release_assets = self.prepare()

        self.assertTrue(archive.is_file())
        self.assertEqual(5, len([path for path in release_assets.iterdir() if path.suffix != ".txt"]))
        version, build, artifacts = ota.verify_bundle(bundle)
        self.assertEqual(("0.5.13", 2026112201), (version, build))
        self.assertEqual(5, len(artifacts))

        destination = self.root / "releases"
        self.assertTrue(ota.apply_bundle(bundle, destination))
        self.assertFalse(ota.apply_bundle(bundle, destination))
        for platform in ota.PLATFORMS:
            self.assertEqual(
                json.loads((bundle / platform / "stable.json").read_text()),
                json.loads((destination / platform / "stable.json").read_text()),
            )

    def test_signer_compose_mounts_the_ota_state_root(self):
        compose = SCRIPT.parents[1] / "release-signer" / "compose.yml"
        expected_mount = f"/var/lib/usernet-release-signer/ota-state:{ota._state_root(Path('/ota/releases'))}:rw"

        self.assertIn(expected_mount, compose.read_text(encoding="utf-8"))

    def test_release_draft_assets_are_bound_to_the_source_commit(self):
        _, _, release_assets = self.prepare()
        source_commit = "a" * 40
        (release_assets / "usernet-release-origin.txt").write_text(
            f"{source_commit}\n",
            encoding="ascii",
        )

        verified = ota.verify_release_artifacts(
            release_assets,
            version="0.5.13",
            build=2026112201,
            source_commit=source_commit,
        )
        self.assertEqual(5, len(verified))
        with self.assertRaisesRegex(ota.OtaError, "different source commit"):
            ota.verify_release_artifacts(
                release_assets,
                version="0.5.13",
                build=2026112201,
                source_commit="b" * 40,
            )

    def test_release_draft_assets_must_match_live_ota_manifests(self):
        bundle, _, release_assets = self.prepare()
        source_commit = "c" * 40
        (release_assets / "usernet-release-origin.txt").write_text(
            f"{source_commit}\n",
            encoding="ascii",
        )
        live_manifests = self.root / "live-manifests"
        for platform in ota.PLATFORMS:
            target = live_manifests / platform / "stable.json"
            target.parent.mkdir(parents=True)
            target.write_bytes((bundle / platform / "stable.json").read_bytes())

        notes_path = self.root / "release-notes.md"
        notes = json.loads((bundle / "android" / "stable.json").read_text())["notes"]
        notes_path.write_text(notes, encoding="utf-8")
        ota.verify_release_matches_manifests(
            release_assets,
            live_manifests,
            version="0.5.13",
            build=2026112201,
            source_commit=source_commit,
            notes_file=notes_path,
        )

        notes_path.write_text("different release notes", encoding="utf-8")
        with self.assertRaisesRegex(ota.OtaError, "release notes differ"):
            ota.verify_release_matches_manifests(
                release_assets,
                live_manifests,
                version="0.5.13",
                build=2026112201,
                source_commit=source_commit,
                notes_file=notes_path,
            )

        manifest_path = live_manifests / "android" / "stable.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["sha256"] = "0" * 64
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ota.OtaError, "Artifact verification failed"):
            ota.verify_release_matches_manifests(
                release_assets,
                live_manifests,
                version="0.5.13",
                build=2026112201,
            )

    def test_release_draft_artifacts_reject_tampered_or_unexpected_files(self):
        _, _, release_assets = self.prepare()
        (release_assets / "usernet-release-origin.txt").write_text(
            f"{'a' * 40}\n",
            encoding="ascii",
        )
        artifact = next(release_assets.glob("*.apk"))
        artifact.write_bytes(b"tampered release apk")

        with self.assertRaisesRegex(ota.OtaError, "Release asset verification failed"):
            ota.verify_release_artifacts(
                release_assets,
                version="0.5.13",
                build=2026112201,
                source_commit="a" * 40,
            )

        _, _, clean_assets = self.prepare("clean-bundle")
        (clean_assets / "unexpected.txt").write_text("unexpected", encoding="utf-8")
        with self.assertRaisesRegex(ota.OtaError, "unexpected asset list"):
            ota.verify_release_artifacts(
                clean_assets,
                version="0.5.13",
                build=2026112201,
            )

    def test_verification_rejects_tampered_artifact_and_untrusted_url(self):
        bundle, _, _ = self.prepare()
        artifact = next((bundle / "android").glob("*.apk"))
        artifact.write_bytes(b"tampered")
        with self.assertRaises(ota.OtaError):
            ota.verify_bundle(bundle)

        bundle, _, _ = self.prepare("other-bundle", 2026112202)
        manifest_path = bundle / "android" / "stable.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["apkUrl"] = "https://attacker.example/usernet.apk"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaises(ota.OtaError):
            ota.verify_bundle(bundle)

    def test_publish_rejects_symlink_targets_and_immutable_conflicts(self):
        bundle, _, _ = self.prepare()
        destination = self.root / "releases"
        destination.mkdir()
        (destination / "android").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ota.OtaError):
            ota.apply_bundle(bundle, destination)

        (destination / "android").unlink()
        self.assertTrue(ota.apply_bundle(bundle, destination))
        changed_inputs = dict(self.inputs)
        changed_inputs["android"] = self.root / "replacement.apk"
        changed_inputs["android"].write_bytes(b"different artifact")
        changed_bundle = self.root / "changed" / "bundle"
        changed_bundle.parent.mkdir()
        ota.prepare_bundle(
            version="0.5.13",
            build=2026112201,
            notes="Release notes",
            inputs=changed_inputs,
            output=self.root / "changed-output",
        )
        with self.assertRaises(ota.OtaError):
            ota.apply_bundle(self.root / "changed-output" / "bundle", destination)

    def test_extract_rejects_traversal_paths(self):
        import io
        import tarfile

        archive_path = self.root / "unsafe.tar.gz"
        with tarfile.open(archive_path, "w:gz") as archive:
            member = tarfile.TarInfo("../escape")
            member.size = 1
            archive.addfile(member, io.BytesIO(b"x"))

        with self.assertRaises(ota.OtaError):
            ota._extract_archive(archive_path, self.root / "extracted")


if __name__ == "__main__":
    unittest.main()
