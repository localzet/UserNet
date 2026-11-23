# UserNet release signer

The signer accepts short-lived GitHub Actions OIDC tokens for the protected
`main` release workflow. It keeps the Android signing key on the server, signs
one stable APK at a time, and delegates OTA bundle validation and atomic
publication to `scripts/usernet_ota.py`.

## Runtime requirements

- Docker Compose and the existing `external` Traefik network.
- Host UID/GID `994`, matching the dedicated `usernet-ota` account.
- The existing OTA release directory mounted read-only, with the four platform
  directories mounted read/write for UID `994`.
- A PKCS#12 signing key and password file mounted read-only, owned by UID
  `994`, with mode `0400`.
- Replay and OTA state directories owned by UID `994`, with mode `0700`.
- `signer.env`, created from `signer.env.example`, with the SHA-256 fingerprint
  of the expected Android signing certificate.

Keep the signing key and password outside the repository and Docker build
context. Do not put them in GitHub Actions secrets or workflow artifacts.

## Local checks

```sh
go test ./...
docker compose -f release-signer/compose.yml config
docker compose -f release-signer/compose.yml build
```

The public `/healthz` endpoint is only a liveness check. Signing and publishing
require a valid OIDC token with the exact repository, protected ref, workflow,
environment, audience, and event claims configured in `signer.env`.

## Release recovery

Rerun a failed release from the same `main` commit. If its GitHub draft is
complete, the workflow verifies its source commit and checksums, then resumes
with those original artifacts. If OTA already contains the release build, the
workflow verifies that the draft assets, public manifests, downloadable files,
notes, and tag target match before publishing the GitHub release. A tag that
targets another commit is rejected; create a new version instead of retargeting
it.
