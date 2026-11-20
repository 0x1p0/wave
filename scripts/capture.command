#!/bin/bash
# Double-click (or `open scripts/capture.command`): runs the guided gesture capture in Terminal.app,
# which has microphone access.
cd "$(dirname "$0")/.." || exit 1
make capture
echo
read -n 1 -s -r -p "Press any key to close this window…"
