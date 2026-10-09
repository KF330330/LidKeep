#!/bin/bash
# Unit tests use temporary files and fake power commands; never install a helper.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-cache"
/usr/bin/swift test --disable-sandbox "$@"
