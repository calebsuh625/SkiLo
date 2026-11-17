#!/bin/zsh
# Builds the SceneKit spike with Command Line Tools only (no xcodebuild).
set -e
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
DIR="$(cd "$(dirname "$0")" && pwd)"
swiftc -parse-as-library -O -target arm64-apple-macosx15.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$DIR"/Sources/*.swift -o "$DIR/SceneKitSpike"
echo "built $DIR/SceneKitSpike"
