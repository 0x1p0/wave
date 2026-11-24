#!/bin/bash
# Double-click (or `open scripts/taps.command`): records table/laptop taps next to real fists in Terminal.app,
# which has microphone access. Quits Wave while recording and reopens it afterwards.
cd "$(dirname "$0")/.." || exit 1
make taps
echo
read -n 1 -s -r -p "Press any key to close this window…"
