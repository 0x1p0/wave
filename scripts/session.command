#!/bin/bash
# Guided gesture session (webcam + instructions + live sonar), run from Terminal (which has mic access).
cd "$(dirname "$0")/.." || exit 1
make session
