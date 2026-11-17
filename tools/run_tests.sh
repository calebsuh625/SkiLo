#!/bin/bash
# Run the package's swift-testing tests with Command Line Tools only.
#
#   tools/run_tests.sh                 # all tests
#   tools/run_tests.sh --filter Rating # suites/tests matching a regex (swift-testing --filter)
#   tools/run_tests.sh --list-tests
#
# Why not `swift test`? Under DEVELOPER_DIR=/Library/Developer/CommandLineTools it builds the test
# bundle and then runs nothing at all (exit 0, no test output) because CLT has no `xctest` host.
# This script builds the tests with SwiftPM, builds tools/testhost (once), and runs the bundle
# through it. Exit code = swift-testing's (0 pass, 1 failures).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
CLT=$DEVELOPER_DIR
ARCH=$(uname -m)
SCRATCH=${SWIFTPM_SCRATCH:-.build}
HOST=$SCRATCH/testhost
if [ ! -x "$HOST" ] || [ tools/testhost/main.swift -nt "$HOST" ]; then
  echo ">> building $HOST"
  mkdir -p "$SCRATCH"
  swiftc -swift-version 5 -target "${ARCH}-apple-macosx15.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -F "$CLT/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" \
    tools/testhost/main.swift -o "$HOST"
fi
swift build --build-tests --scratch-path "$SCRATCH" 2>&1 | tail -3
BUNDLE="$SCRATCH/${ARCH}-apple-macosx/debug/SkiLoPackageTests.xctest/Contents/MacOS/SkiLoPackageTests"
test -f "$BUNDLE" || { echo "test bundle not found: $BUNDLE"; exit 2; }
HT_TEST_BUNDLE="$BUNDLE" exec "$HOST" "$@"
