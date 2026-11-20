SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

DERIVED := build/DerivedData
# variant=macos avoids xcodebuild picking among Mac / Catalyst / DriverKit / "Designed for iPad".
DEST    := platform=macOS,arch=$(shell uname -m),variant=macos
PROBE   := $(DERIVED)/Build/Products/Release/wave-probe
# Harmless internal xcodebuild log line for Swift packages.
QUIET   := grep -v 'IDERunDestination: Supported platforms' || true

.PHONY: probe test devices speakers sweep sweep96 live clean

probe:
	@xcodebuild -scheme wave-probe -destination '$(DEST)' -derivedDataPath $(DERIVED) -configuration Release build -quiet 2>&1 | { $(QUIET); }
	@echo "Built $(PROBE)"

test:
	xcodebuild test -scheme Wave-Package -destination '$(DEST)' -derivedDataPath $(DERIVED) 2>&1 | grep -E '✔ Test run|✘|error:|TEST (SUCCEEDED|FAILED)'

devices: probe
	$(PROBE) devices

# Built-in speakers' own volume (default 50 %), without changing the default output. VOL=75 make speakers
speakers: probe
	$(PROBE) speakers --volume $(or $(VOL),50)

# M0 feasibility sweep at the mic's current rate (48 kHz). Report → docs/m0-sweep-48k.md
sweep: probe
	$(PROBE) sweep --out docs/m0-sweep-48k.md

# Same sweep with the mic temporarily at 96 kHz (restored afterwards).
sweep96: probe
	$(PROBE) sweep --rate 96000 --out docs/m0-sweep-96k.md

live: probe
	$(PROBE) live --freq $(or $(FREQ),20000)

clean:
	rm -rf build .build
