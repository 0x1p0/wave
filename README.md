# Wave

Hand gestures in the air over a MacBook, detected with ultrasonic sonar. The built-in speakers play an
inaudible pilot tone, the built-in mics hear its reflection off your hand, and the Doppler shift tells
which way your hand moved. No camera, no extra hardware.

**Status: M0 (feasibility probe).** The menu bar app arrives in M2.

## Privacy

Audio is analysed in memory and never leaves the Mac. Nothing is written to disk except opt-in debug
recordings (added in M1). The probe writes only a Markdown table of numbers.

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
make sweep     # 17–22.5 kHz sweep → docs/m0-sweep-48k.md
make sweep96   # same with the mic temporarily at 96 kHz → docs/m0-sweep-96k.md
make live      # live spectrogram around 20 kHz (FREQ=19000 make live for another pilot)
```

The pilot always goes to the **built-in speakers** and is captured from the **built-in mic**, whatever
the system default devices are (AirPods, wired headphones, …). The speakers must not be muted, and their
own volume (separate from your headphones' volume) should be ~50 % for the probe.

Run it from a terminal app that has microphone access (System Settings → Privacy & Security →
Microphone). The orange mic indicator is on while the probe runs.

## Layout

```
Sources/WaveRT/        C11 atomics + signal flag (Swift's Atomic needs macOS 15)
Sources/WaveCore/      Audio (Core Audio devices, AUHAL pilot player + mic capture, ring buffer)
                       DSP (vDSP FFT, frame slicer, pilot band metrics, synthetic signals)
Sources/wave-probe/    M0 CLI: devices / sweep / live
Tests/WaveCoreTests/   Swift Testing unit tests
docs/                  Assumptions and probe reports
```
