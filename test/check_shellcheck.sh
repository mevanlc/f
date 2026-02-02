#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found; skipping" >&2
  exit 0
fi

shellcheck \
  "$root/f" \
  "$root/test/run.sh" \
  "$root/test/check_shellcheck.sh" \
  "$root"/test/test_*/f_cmd.sh \
  "$root"/test/test_*/fd_cmd.sh

