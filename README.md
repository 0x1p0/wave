# Wave

Hand gestures in the air over a MacBook, detected with ultrasonic sonar. The built-in speakers play an
inaudible pilot tone, the built-in mics hear its reflection off your hand, and the Doppler shift tells
which way your hand moved. No camera, no extra hardware.

**Status: M1 (detection engine).** M0 found it feasible in a narrow 18.75–19.25 kHz window (19 kHz pilot at
−8 dBFS), see [docs/M0-FINDINGS.md](docs/M0-FINDINGS.md). The menu bar app arrives in M2.

## Privacy

Audio is analysed in memory and never leaves the Mac. Nothing is written to disk except **opt-in debug
recordings** (`make record`, or Record in the debug window), saved to
`~/Library/Application Support/Wave/Recordings` as `.caf` + `.json`. The probe writes only tables of numbers.

## Build

Requires Xcode 16+ (Swift 6) on macOS 14+. Apple frameworks only.

```sh
make probe     # xcodebuild → build/DerivedData/Build/Products/Release/wave-probe
make test      # unit tests (xcodebuild test)
```

`swift build` / `swift test` also work.

## M0 probe

```sh
make devices   # machine + audio hardware report (plays/records nothing)
make speakers  # set the built-in speakers' own volume to 50 % (VOL=75 make speakers), default output unchanged
make sweep     # 17–22.5 kHz sweep → docs/m0-sweep-48k.md
make sweep96   # same with mic + speakers temporarily at 96 kHz → docs/m0-sweep-96k.md
make confirm   # 18.5–19.5 kHz at −8 dBFS, still + waving → docs/m0-sweep-19k-loud.md
make live      # live spectrogram around 19 kHz at −8 dBFS (FREQ=18750 AMP=-12 make live)
```

The pilot always goes to the **built-in speakers** and is captured from the **built-in mic**, whatever
the system default devices are (AirPods, wired headphones, …). The speakers must not be muted, and their
own volume (separate from your headphones' volume) should be ~50 % for the probe: `make speakers` sets that
directly through Core Audio without switching your output away from your headphones.

Run it from a terminal app that has microphone access (System Settings → Privacy & Security →
Microphone). The orange mic indicator is on while the probe runs.

## M1 detection

```sh
make debug     # debug window: live spectrogram, feature traces, event log with confidence
make detect    # same detector in the terminal (SENS=0.7 make detect)
make record    # detect + save raw mic audio for replay (LABEL=push make record)
make replay FILE=path/to/wave-….caf   # rerun the detector on a recording (SENS=0.6 to compare)
make demo      # synthetic recording (no waving needed), replayed in the terminal and the window
```

`wave-probe replay FILE --csv out.csv` dumps per-frame features; `wave-probe config > my.json` prints the
detector settings, which `--config my.json` reads back, so tuning is repeatable on the same audio.

**How a push is detected** (per pilot, every 10.7 ms):

- *Features*: energy just above the pilot (hand moving toward the screen) and just below it (moving away),
  each in dB over an adaptive still-hand baseline; a reference band 470–700 Hz from the pilot where hand
  Doppler can't reach; the Doppler-centroid speed; reflection strength.
- *Push*: a toward phase (≥ 8 dB, ≥ 3 dB more than the other side, centroid ≥ +0.25 m/s), then within 0.25 s
  an away phase with the same rules mirrored; 0.2–0.75 s in total; both peaks ≥ 10 dB. Sensitivity shifts
  every dB threshold by up to ±6 dB.
- *Rejected* (shown in the log, never acted on): keyboard/trackpad input within 0.8 s (IOHIDSystem
  `HIDIdleTime`, no permission needed), broadband noise (reference band ≥ 6 dB), too slow (one-way motion,
  people walking by), too fast, too weak, no return movement. Slow drift never leaves the pilot's own bins.
- *Volume*: the pilot's acoustic level is held constant: −8 dBFS at a speaker gain of −18.6 dB (50 %), more
  or less digital level as the speakers' own volume changes, up to −2 dBFS. Below ≈ −24.6 dB, or when muted,
  Wave pauses with "Volume too low for Wave" / "Built-in speakers are muted".

## Layout

```
Sources/WaveRT/        C11 atomics + signal flag (Swift's Atomic needs macOS 15)
Sources/WaveCore/      Audio (Core Audio devices, AUHAL pilot player + mic capture, ring buffer)
                       DSP (vDSP FFT, frame slicer, pilot band metrics, synthetic signals)
                       Detection (features, push detector), Engine (pipeline, live engine, volume policy)
                       Recording (CAF + JSON sidecar, replay), System (HIDIdleTime, machine info)
Sources/WaveUI/        SwiftUI debug views (spectrogram, traces, event log)
Sources/wave-debug/    M1 debug window app (run from Terminal)
Sources/wave-probe/    CLI: devices / speakers / sweep / live (M0), detect / replay / config / synth (M1)
Tests/WaveCoreTests/   Swift Testing unit tests (synthetic Doppler gestures, record/replay, …)
docs/                  Assumptions and probe reports
```
