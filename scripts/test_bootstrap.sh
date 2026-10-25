#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${WORKSPACE_ROOT}/macos/Bootstrap"
MODULE_CACHE_DIR="${WORKSPACE_ROOT}/build/module-cache"
SWIFT_BUILD_DIR="${WORKSPACE_ROOT}/build/swift"
SWIFT_CACHE_DIR="${WORKSPACE_ROOT}/build/swiftpm/cache"
SWIFT_CONFIG_DIR="${WORKSPACE_ROOT}/build/swiftpm/config"
SWIFT_SECURITY_DIR="${WORKSPACE_ROOT}/build/swiftpm/security"

mkdir -p "${MODULE_CACHE_DIR}" "${SWIFT_BUILD_DIR}" "${SWIFT_CACHE_DIR}" \
    "${SWIFT_CONFIG_DIR}" "${SWIFT_SECURITY_DIR}"
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE_DIR}"
export SWIFT_MODULECACHE_PATH="${MODULE_CACHE_DIR}"

"${WORKSPACE_ROOT}/scripts/test_swcli_launcher.sh"
python3 -m unittest discover -s "${WORKSPACE_ROOT}/scripts/tests" -p 'test_*.py'

swift test \
    --package-path "${PACKAGE_DIR}" \
    --scratch-path "${SWIFT_BUILD_DIR}" \
    --cache-path "${SWIFT_CACHE_DIR}" \
    --config-path "${SWIFT_CONFIG_DIR}" \
    --security-path "${SWIFT_SECURITY_DIR}"
