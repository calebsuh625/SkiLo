#!/bin/zsh
# Builds both spikes with Command Line Tools only (no xcodebuild, no .app bundle).
#   spike    = SwiftUI Map (MapPolyline, MapReader picking)
#   spike_mk = MKMapView via NSViewRepresentable (MKPolyline overlays, renderer recolor, didFinishRendering timing)
set -e
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cd "$(dirname "$0")"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
FLAGS=(-parse-as-library -swift-version 5 -target arm64-apple-macosx15.0 -sdk "$SDK" -O)
START=$(date +%s.%N)
swiftc "${FLAGS[@]}" Shared.swift main.swift -o spike
MID=$(date +%s.%N)
swiftc "${FLAGS[@]}" Shared.swift MKSpike.swift -o spike_mk
END=$(date +%s.%N)
printf "compile time: spike %.1fs, spike_mk %.1fs\n" "$(echo "$MID - $START" | bc)" "$(echo "$END - $MID" | bc)"
ls -la spike spike_mk
