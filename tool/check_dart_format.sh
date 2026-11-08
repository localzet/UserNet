#!/usr/bin/env bash
set -euo pipefail

base_ref="${1:-}"
if [[ ! "$base_ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo 'Usage: tool/check_dart_format.sh <base-commit-sha>' >&2
  exit 2
fi

if [[ "$base_ref" =~ ^0{40}$ ]]; then
  base_ref="HEAD^"
fi

mapfile -d '' -t dart_files < <(
  git diff --name-only --diff-filter=ACMR -z "$base_ref" HEAD -- '*.dart'
)

if ((${#dart_files[@]} == 0)); then
  echo 'No changed Dart files to format-check.'
  exit 0
fi

if ! dart format --output=none --set-exit-if-changed "${dart_files[@]}"; then
  dart format "${dart_files[@]}"
  echo 'Apply this formatter diff to the source branch:' >&2
  git diff -- "${dart_files[@]}" >&2
  exit 1
fi
