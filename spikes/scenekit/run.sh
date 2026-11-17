#!/bin/zsh
# Usage: run.sh [screenshot.png]  (env: DEM_STRIDE=2 SPIKE_TEXTURE=hillshade_tex.png|satellite_z15.jpg|satellite_z14.jpg|none SPIKE_DELAY=6.5)
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -n "$1" ]; then export SPIKE_SCREENSHOT="$1" SPIKE_AUTOEXIT=1; fi
export SPIKE_DIR="$DIR"
exec "$DIR/SceneKitSpike"
