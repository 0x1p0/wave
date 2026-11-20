#!/bin/bash
# Average CPU of the running Wave app over ~20 s (10 samples, 2 s apart). Target: under 3 %.
set -euo pipefail
pid=$(pgrep -x Wave || true)
if [ -z "$pid" ]; then
  echo "Wave isn't running."
  exit 1
fi
# top's first sample has no history; skip it.
top -l 11 -s 2 -pid "$pid" -stats cpu \
  | grep -E '^[0-9]+(\.[0-9]+)?$' \
  | tail -10 \
  | awk '{ s += $1; n++ } END { printf "Wave CPU: %.1f %% average over %d samples (2 s each)\n", s / n, n }'
