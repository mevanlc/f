#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

exec cargo run --manifest-path tests/fd_compat/Cargo.toml -- "$@"

