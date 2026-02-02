#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures/complex"

fd -t d -g '*resvg*' --and '*ws*'

