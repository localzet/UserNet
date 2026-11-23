#!/usr/bin/env python3
"""Resolve the commit targeted by a UserNet GitHub release tag."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


GITHUB_API = "https://api.github.com"
COMMIT_SHA = re.compile(r"[a-f0-9]{40}")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
RELEASE_TAG = re.compile(r"v\d+\.\d+\.\d+")


class ReleaseTagError(Exception):
    pass


def _fetch_json(path: str, token: str, *, missing_ok: bool = False) -> dict | None:
    request = Request(
        f"{GITHUB_API}/{path}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "UserNet-release-workflow",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urlopen(request, timeout=10) as response:
            payload = json.load(response)
    except HTTPError as error:
        if missing_ok and error.code == 404:
            error.close()
            return None
        error.close()
        raise ReleaseTagError(f"GitHub tag API returned HTTP {error.code}") from error
    except (OSError, URLError, json.JSONDecodeError) as error:
        raise ReleaseTagError("GitHub tag API request failed") from error
    if not isinstance(payload, dict):
        raise ReleaseTagError("GitHub tag API returned invalid data")
    return payload


def resolve_tag_commit(repository: str, tag: str, token: str) -> str | None:
    if not REPOSITORY.fullmatch(repository) or not RELEASE_TAG.fullmatch(tag):
        raise ReleaseTagError("Invalid repository or release tag")
    if not token:
        raise ReleaseTagError("GitHub token is unavailable")

    encoded_tag = quote(tag, safe="")
    reference = _fetch_json(
        f"repos/{repository}/git/ref/tags/{encoded_tag}",
        token,
        missing_ok=True,
    )
    if reference is None:
        return None

    target = reference.get("object")
    for _ in range(4):
        if not isinstance(target, dict):
            raise ReleaseTagError("GitHub release tag has an invalid target")
        target_type = target.get("type")
        target_sha = target.get("sha")
        if not isinstance(target_sha, str) or not COMMIT_SHA.fullmatch(target_sha):
            raise ReleaseTagError("GitHub release tag has an invalid object ID")
        if target_type == "commit":
            return target_sha
        if target_type != "tag":
            raise ReleaseTagError("GitHub release tag does not resolve to a commit")
        annotated = _fetch_json(f"repos/{repository}/git/tags/{target_sha}", token)
        assert annotated is not None
        target = annotated.get("object")

    raise ReleaseTagError("GitHub release tag nesting is too deep")


def validate_tag_target(
    tag_commit: str | None,
    source_commit: str,
    candidate_build: int,
    remote_build: int,
    release_exists: bool,
) -> None:
    if not COMMIT_SHA.fullmatch(source_commit):
        raise ReleaseTagError("Invalid source commit")
    if release_exists and tag_commit is None:
        raise ReleaseTagError("GitHub release exists without its Git tag")
    if tag_commit is not None and not COMMIT_SHA.fullmatch(tag_commit):
        raise ReleaseTagError("Invalid GitHub release tag target")
    if candidate_build > remote_build and tag_commit and tag_commit != source_commit:
        raise ReleaseTagError("Existing release tag targets a different source commit")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    resolve = commands.add_parser("resolve-tag-commit")
    resolve.add_argument("repository")
    resolve.add_argument("tag")
    validate = commands.add_parser("validate-tag-target")
    validate.add_argument("--tag-commit")
    validate.add_argument("--source-commit", required=True)
    validate.add_argument("--candidate-build", required=True, type=int)
    validate.add_argument("--remote-build", required=True, type=int)
    validate.add_argument("--release-exists", choices=("true", "false"), required=True)
    args = parser.parse_args()
    try:
        if args.command == "resolve-tag-commit":
            commit = resolve_tag_commit(
                args.repository,
                args.tag,
                os.environ.get("GH_TOKEN", ""),
            )
            print(commit or "")
        else:
            validate_tag_target(
                args.tag_commit,
                args.source_commit,
                args.candidate_build,
                args.remote_build,
                args.release_exists == "true",
            )
    except ReleaseTagError as error:
        print(f"Release tag verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
