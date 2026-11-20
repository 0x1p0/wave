# Assumptions and decisions

Recorded at M0 (2026-11-20). Revisit when a milestone proves one wrong.

## Hardware (this Mac)

- MacBook Air 13" M4 (Mac16,12), macOS 27.2.1, Xcode 27.2 / Swift 6.4.
- `MacBook Air Speakers` (UID `BuiltInSpeakerDevice`, data source `ispk`): 2 ch; supports 44.1/48/88.2/96 kHz.
- `MacBook Air Microphone` (UID `BuiltInMicrophoneDevice`, data source `imic`): **1 channel**;
  supports 44.1/48/88.2/96 kHz. The mic array is beamformed in hardware/driver and exposed as one channel.
- The 3.5 mm jack appears as separate devices (`External Headphones` / `External Microphone`) that **also
  report transport = built-in**, so built-in selection excludes them by UID/data source/name.

## Build & structure

- Swift package: `WaveCore` (library), `wave-probe` (CLI), tests. Built with `xcodebuild`.
- M2 adds a hand-written `Wave.xcodeproj` (app target, hardened runtime, Developer ID) that depends on the
  local package. No XcodeGen/Tuist (they would be dependencies).
- Tiny C target `WaveRT` for C11 atomics and an async-signal-safe Ctrl-C flag, because
  `Synchronization.Atomic` requires macOS 15 and the deployment target is 14.
- Tests use Swift Testing (ships with Xcode).

## Audio

- Devices are always chosen explicitly via Core Audio (`kAudioOutputUnitProperty_CurrentDevice`);
  the system default devices are never used.
- Separate AUHAL units for output (pilot) and input (capture). The detector looks only at the received
  spectrum, never at output/input timing alignment.
- AUHAL capture = raw: no voice processing, AGC or noise suppression. The mic's hardware input gain is left
  as the user set it and reported.
- Sample rate: **48 kHz, decided at M0** (96 kHz measured identical; see M0-FINDINGS.md). Wave never changes
  device sample rates: it's system-wide, and a capture started during an async rate change can stay silent.
  The probe's `--rate`/`--speaker-rate` exist only for measurement and restore afterwards.
- Real-time threads: no allocation, no blocking locks. Parameters cross with try-lock
  (`OSAllocatedUnfairLock.withLockIfAvailable`) and fixed-size value types; audio crosses via an SPSC ring buffer.
- Pilot: pure sine with 50 ms raised-cosine fades on every start, stop and frequency change.
- Pilot frequencies are snapped to FFT bin centres (fs/N) so a steady pilot doesn't leak into its sidebands.

## Detection (M0 definitions, refined in M1)

- Hann window, FFT 4096, hop 512 @ 48 kHz → 11.72 Hz bins, 10.7 ms hops, 85 ms windows.
- Doppler band per pilot: ±3…32 bins (±35–375 Hz ≈ 0.3–3.2 m/s at 20 kHz). ±2 bins are the pilot's own.
- Toward the laptop = reflection shifts **up** (upper sideband); away = down.
- "Doppler visible" (M0) = while waving, 95th-percentile sideband energy is ≥ 6 dB above the still-hand mean
  on **both** sides.
- Frequencies below 18.5 kHz are treated as potentially audible and not recommended.
- M0 result: usable pilot window on this Mac is ~18.75–19.25 kHz; default pilot 19 kHz (18 996.1 Hz) at
  −8 dBFS with the speakers at 50 % (−18.6 dB); fallback 19.25 kHz.
- Broadband noise bursts can raise both sidebands without any pilot; the detector needs a reference band.

## Volume

- System volume and mute scale the pilot. Volume keys only change the *default* output device, so when
  audio goes to headphones/AirPods the speakers keep their own last volume (on this Mac at M0: 0 %, muted).
- Wave never changes the system volume or mute itself. It compensates digitally within limits (M2) and
  otherwise pauses with "Volume too low for Wave".

## Permissions

- The CLI's microphone permission belongs to the terminal app that runs it. Wave.app gets its own (M2).
- Posting media keys needs Accessibility (M2).
