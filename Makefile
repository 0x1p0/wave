# macOS ships GNU make 3.81 (no .SHELLFLAGS), so piped recipes set pipefail themselves.
SHELL := /bin/bash

DERIVED := build/DerivedData
# variant=macos avoids xcodebuild picking among Mac / Catalyst / DriverKit / "Designed for iPad".
DEST    := platform=macOS,arch=$(shell uname -m),variant=macos
PROBE   := $(DERIVED)/Build/Products/Release/wave-probe
# Harmless internal xcodebuild log line for Swift packages.
QUIET   := grep -v 'IDERunDestination: Supported platforms' || true

.PHONY: probe app-debug app install run cpu test devices speakers sweep sweep96 confirm live debug detect record replay demo demo-hold capture taps tutorial session session-extras clean

probe:
	@set -o pipefail; xcodebuild -scheme wave-probe -destination '$(DEST)' -derivedDataPath $(DERIVED) -configuration Release build -quiet 2>&1 | { $(QUIET); }
	@echo "Built $(PROBE)"

DEBUG_APP := $(DERIVED)/Build/Products/Release/wave-debug

app-debug:
	@set -o pipefail; xcodebuild -scheme wave-debug -destination '$(DEST)' -derivedDataPath $(DERIVED) -configuration Release build -quiet 2>&1 | { $(QUIET); }
	@echo "Built $(DEBUG_APP)"

test:
	@set -o pipefail; xcodebuild test -scheme Wave-Package -destination '$(DEST)' -derivedDataPath $(DERIVED) 2>&1 | grep -E '✔ Test run|✘|error:|TEST (SUCCEEDED|FAILED)'

devices: probe
	$(PROBE) devices

# Built-in speakers' own volume (default 50 %), without changing the default output. VOL=75 make speakers
speakers: probe
	$(PROBE) speakers --volume $(or $(VOL),50)

# M0 feasibility sweep at the mic's current rate (48 kHz). Report → docs/m0-sweep-48k.md
sweep: probe
	$(PROBE) sweep --out docs/m0-sweep-48k.md

# Same sweep with mic and speakers temporarily at 96 kHz (restored afterwards).
sweep96: probe
	$(PROBE) sweep --rate 96000 --speaker-rate 96000 --out docs/m0-sweep-96k.md

# M0 confirmation: 18.5–19.5 kHz with a louder pilot (−8 dBFS), both passes (~30 s).
confirm: probe
	$(PROBE) sweep --start 18500 --end 19500 --step 250 --amplitude -8 --out docs/m0-sweep-19k-loud.md

# Live view around the recommended pilot. FREQ=18750 AMP=-12 make live
live: probe
	$(PROBE) live --freq $(or $(FREQ),19000) --amplitude $(or $(AMP),-8)

# ---- The app (M2+) ------------------------------------------------------------------------------

APP_DERIVED := build/AppDerivedData
APP         := $(APP_DERIVED)/Build/Products/Release/Wave.app
# Sign with your Apple Development / Developer ID identity if you have one, so macOS keeps the
# Microphone and Accessibility permissions across rebuilds (ad-hoc signatures change every build).
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 -oE '"(Developer ID Application|Apple Development)[^"]*"' | tr -d '"')
APP_SIGN = $(if $(SIGN_ID),CODE_SIGN_IDENTITY="$(SIGN_ID)",)

app:
	@set -o pipefail; xcodebuild -project App/Wave.xcodeproj -scheme Wave -configuration Release \
		-derivedDataPath $(APP_DERIVED) -destination '$(DEST)' $(APP_SIGN) build -quiet 2>&1 | { $(QUIET); }
	@echo "Built $(APP) ($(if $(SIGN_ID),signed with your development identity,ad-hoc signed))"

# Install into /Applications (where Launch at Login expects it) and start it.
install: app
	@osascript -e 'tell application id "local.wave.Wave" to quit' >/dev/null 2>&1; sleep 1; true
	ditto "$(APP)" /Applications/Wave.app
	open /Applications/Wave.app
	@echo "Wave is running: look for the hand icon in the menu bar."

# Install, start, and open the live gesture tutorial (a fresh launch, so the argument reaches the app).
tutorial: app
	@osascript -e 'tell application id "local.wave.Wave" to quit' >/dev/null 2>&1; sleep 1; true
	ditto "$(APP)" /Applications/Wave.app
	open -n /Applications/Wave.app --args --tutorial

# Run the freshly built app without installing.
run: app
	@osascript -e 'tell application id "local.wave.Wave" to quit' >/dev/null 2>&1; sleep 1; true
	open "$(APP)"

# CPU use of the running app over ~20 s (target: under 3 % on Apple Silicon).
cpu:
	@scripts/cpu.sh

# ---- M1: detection ----------------------------------------------------------------------------

# Debug window: live spectrogram, feature traces, event log. Close the window (or Ctrl-C) to stop.
debug: app-debug
	$(DEBUG_APP)

# Live push detection in the terminal. SENS=0.7 make detect
detect: probe
	$(PROBE) detect --sensitivity $(or $(SENS),0.5)

# Same, also saving raw mic audio for replay (debug, opt-in). LABEL=push make record
record: probe
	$(PROBE) detect --sensitivity $(or $(SENS),0.5) --record $(if $(LABEL),--label $(LABEL),)

# Replay a recording through the detector. FILE=~/Library/.../wave-….caf [SENS=0.6] make replay
replay: probe
	$(PROBE) replay "$(FILE)" $(if $(SENS),--sensitivity $(SENS),)

# Synthetic demo recording (no waving needed): replay it in the terminal, then in the debug window.
demo: probe app-debug
	$(PROBE) synth build/demo.caf
	$(PROBE) replay build/demo.caf
	$(DEBUG_APP) --replay build/demo.caf

# Guided gesture session: webcam + big instructions + live sonar, logging everything for tuning.
DEMO_APP := $(DERIVED)/Build/Products/Release/wave-demo
session:
	@set -o pipefail; xcodebuild -scheme wave-demo -destination '$(DEST)' -derivedDataPath $(DERIVED) -configuration Release build -quiet 2>&1 | { $(QUIET); }
	$(DEMO_APP)

# The same, for walk away / come back and air letters.
session-extras:
	@set -o pipefail; xcodebuild -scheme wave-demo -destination '$(DEST)' -derivedDataPath $(DERIVED) -configuration Release build -quiet 2>&1 | { $(QUIET); }
	$(DEMO_APP) --extras

# Guided ~1 minute recording of your real gestures for tuning (quits and reopens the Wave app).
capture: probe
	$(PROBE) capture

# Table/laptop taps next to real fists (~1 minute), to teach the grab detector the difference.
taps: probe
	$(PROBE) capture --taps

# Synthetic hold demo: approach + hold, slide closer (dial up), pull away, approach + grab.
demo-hold: probe app-debug
	$(PROBE) synth --hold build/demo-hold.caf
	$(PROBE) replay build/demo-hold.caf
	$(DEBUG_APP) --replay build/demo-hold.caf

clean:
	rm -rf build .build
