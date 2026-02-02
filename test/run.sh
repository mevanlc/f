#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v fd >/dev/null 2>&1; then
  echo "error: fd not found on PATH" >&2
  exit 127
fi

export LC_ALL=C

fail=0
count=0

for tdir in "$root"/test/test_*; do
  [ -d "$tdir" ] || continue
  count=$((count + 1))
  name="$(basename -- "$tdir")"

  expected="$tdir/expected.txt"
  if [ ! -f "$expected" ]; then
    echo "FAIL $name: missing expected.txt" >&2
    fail=1
    continue
  fi

  for variant in f fd; do
    cmd="$tdir/${variant}_cmd.sh"
    if [ ! -f "$cmd" ]; then
      echo "FAIL $name: missing ${variant}_cmd.sh" >&2
      fail=1
      continue
    fi

    out="$(mktemp -t "f-test.${name}.${variant}.XXXXXX")"

    if ! bash "$cmd" >"$out"; then
      echo "FAIL $name ($variant): command failed" >&2
      fail=1
      rm -f "$out"
      continue
    fi

    if ! diff -u "$expected" "$out" >/dev/null; then
      echo "FAIL $name ($variant): output mismatch" >&2
      diff -u "$expected" "$out" >&2 || true
      fail=1
      rm -f "$out"
      continue
    fi

    rm -f "$out"
  done

  echo "PASS $name"
done

if [ $count -eq 0 ]; then
  echo "error: no tests found under test/test_*" >&2
  exit 2
fi

exit $fail

