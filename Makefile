SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

DERIVED := build/DerivedData
DEST    := platform=macOS,arch=$(shell uname -m)
PROBE   := $(DERIVED)/Build/Products/Release/wave-probe

.PHONY: probe test devices sweep sweep96 live clean

probe:
	xcodebuild -scheme wave-probe -destination '$(DEST)' -derivedDataPath $(DERIVED) -configuration Release build -quiet
	@echo "Built $(PROBE)"

test:
	xcodebuild test -scheme Wave-Package -destination '$(DEST)' -derivedDataPath $(DERIVED) 2>&1 | grep -E '✔ Test run|✘|error:|TEST (SUCCEEDED|FAILED)'

devices: probe
	$(PROBE) devices

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
