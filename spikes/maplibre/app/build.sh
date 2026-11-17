#!/bin/sh
# Build the spike without xcodebuild (Command Line Tools only).
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -parse-as-library -target arm64-apple-macosx15.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" -O main.swift -o Spike
echo "built $(pwd)/Spike"
