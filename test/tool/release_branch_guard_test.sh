#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
release_script="$repo_root/tool/release.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

setup_repo() {
  local dir="$1"
  mkdir -p "$dir/tool"
  cp "$release_script" "$dir/tool/release.sh"
  cat >"$dir/tool/bump_version.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$dir/tool/bump_version.sh"
  printf 'name: release-guard-test\nversion: 1.2.3+1\n' >"$dir/pubspec.yaml"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name test
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" add tool pubspec.yaml
  git -C "$dir" commit -qm initial
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "expected error '$expected' from: $*" >&2
    echo "$output" >&2
    exit 1
  fi
}

non_main="$tmp_root/non-main"
setup_repo "$non_main"
git -C "$non_main" update-ref refs/remotes/origin/main HEAD
git -C "$non_main" switch -q -c release/test
expect_failure "stable releases must start from main" \
  "$non_main/tool/release.sh" stable --dry-run

missing_remote="$tmp_root/missing-remote"
setup_repo "$missing_remote"
expect_failure "origin/main is missing" \
  "$missing_remote/tool/release.sh" stable --dry-run

unreachable="$tmp_root/unreachable"
setup_repo "$unreachable"
tree="$(git -C "$unreachable" mktree </dev/null)"
unrelated="$(printf 'unrelated\n' | git -C "$unreachable" commit-tree "$tree")"
git -C "$unreachable" update-ref refs/remotes/origin/main "$unrelated"
expect_failure "HEAD is not reachable from origin/main" \
  "$unreachable/tool/release.sh" stable --dry-run

prerelease="$tmp_root/prerelease"
setup_repo "$prerelease"
git -C "$prerelease" switch -q -c release/test
"$prerelease/tool/release.sh" pre --dry-run >/dev/null

echo 'release branch guard checks passed'
