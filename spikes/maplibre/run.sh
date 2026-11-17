#!/bin/sh
# Build (if needed) and run the spike. It self-captures to out/ and exits after ~15 s.
# SPIKE_AUTOEXIT=0 ./run.sh   -> keeps the window open for manual poking (click trails, rotate, tilt).
set -e
cd "$(dirname "$0")"
[ -x app/Spike ] || ./app/build.sh
mkdir -p out
exec ./app/Spike
