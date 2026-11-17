#!/bin/zsh
# Usage: ./run.sh [realistic|flat] [delaySeconds] [hybrid|imagery|standard]
# Launches the spike (bare executable, no bundle), which screenshots itself into ./out and exits.
cd "$(dirname "$0")"
export SPIKE_ELEVATION="${1:-realistic}" SPIKE_DELAY="${2:-12}" SPIKE_STYLE="${3:-hybrid}"
export SPIKE_OUT="$(pwd)/out"
LOG="out/run_${SPIKE_STYLE}_${SPIKE_ELEVATION}.log"
mkdir -p out
echo "launching $(date +%T) elevation=$SPIKE_ELEVATION delay=$SPIKE_DELAY style=$SPIKE_STYLE" | tee "$LOG"
./spike >> "$LOG" 2>&1
echo "exit $? at $(date +%T)" | tee -a "$LOG"
