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

## Detection (M1)

- Features per pilot per frame: toward/away sideband energy (±3…32 bins) in dB over a per-bin baseline;
  reference bands at ±40…60 bins (470–700 Hz) for broadband-noise rejection; Doppler centroid velocity from
  bins > 3× baseline; reflection strength vs the pilot.
- Baseline: fast average during 0.6 s warm-up, then τ = 1.5 s while quiet, τ = 20 s otherwise; reset when the
  pilot level changes by > 1 dB or the pilot resumes.
- Push thresholds (sensitivity 0.5): on 8 dB, off 4 dB, peak 10 dB, dominance 3 dB, |v| ≥ 0.25 m/s,
  0.2–0.75 s total, ≤ 0.25 s reversal gap, input guard 0.8 s, reference reject 6 dB, refractory 0.4 s.
  A real still scene (person at the laptop) measured toward/away p99 ≈ +5.5 dB, max +6.4 dB.
- Two pilots (M3) each get a detector; accepted pushes within 0.3 s are merged.
- Debug recordings: float32 CAF + JSON sidecar (pilots, level, speaker gain, input times, live events,
  detector settings, label). Sidecar decoding tolerates missing/new fields.

## Detection (M0 definitions)

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

## App (M2–M5)

- `App/Wave.xcodeproj` is hand-written (objectVersion 77, file-system-synchronized `Wave/` folder) and links
  the local package's `WaveCore` and `WaveUI` products. Menu bar only (`LSUIElement`), not sandboxed,
  hardened runtime with `com.apple.security.device.audio-input`.
- Bundle ID `local.wave.Wave`: a placeholder to change before distributing.
- Signing: `make` uses an Apple Development / Developer ID identity from the keychain when present (stable
  identity → TCC keeps Microphone/Accessibility grants across rebuilds); otherwise ad-hoc.
  `scripts/release.sh` archives universal, signs with Developer ID, drops `get-task-allow`, notarizes, staples.
- Actions: media keys are NX_SYSDEFINED events posted with CGEvent (needs Accessibility); keyboard
  shortcuts likewise; Shortcuts run via `/usr/bin/shortcuts run NAME`.
- "Media playing" = another process has Core Audio output running (process objects, macOS 14.2+), excluding
  Wave. Some apps keep idle streams open (Signal Desktop), hence the per-app ignore list. Grace period
  after playback stops or a gesture fires (default 3 min) so a push can resume what it paused.
- Lid state: IOPMrootDomain `AppleClamshellState`, polled every 2 s. Screen lock: distributed
  `com.apple.screenIsLocked/Unlocked`. Display/system sleep and session switches: NSWorkspace.
- One engine at a time: calibration, sample recording and the debug window take it over (the debug window
  runs its own engine while the app's is stopped; gestures still trigger actions).
- Swipes (experimental): left 18.75 kHz / right 19.5 kHz, each Doppler band narrowed to ±30 bins, reference
  bands on the outer sides, push-vs-swipe by reversal lag (default 45 ms, learned by calibration together
  with the direction).
- Calibration thresholds: start = max(noise + 2, 0.45 × typical peak) within 4…14 dB; peak = max(start + 1,
  noise + 3, min(lowest − 2, 0.75 × typical)); durations from the examples; sensitivity then shifts ±6 dB.

## Hold & slide, grab, more actions (after M5)

- Phase tracker per pilot (`BasebandTracker`): mix to 0 Hz, 24-sample boxcar → 2 kHz, 4th-order Butterworth
  low-pass at 100 Hz (rejects the other stereo pilot by ~70 dB), ÷4 → 500 Hz; static vector = 0.4 s
  exponential average; phase steps of the remainder only when it is ≥ 12× its quiet level for two samples in a
  row; hand displacement = Δphase · c / (4π f) (speaker and mic treated as co-located). The quiet level is
  tracked in dB so sustained motion can't drag it up.
- `InteractionDetector`: approach (Doppler toward) → 0.35 s of stillness → ready ✋. From ready: slide past a
  1.2 cm dead zone → dial (5 % per cm by default, adjustments held 150 ms so a fast pull-away can't nudge the
  level); a micro-motion burst ≥ 10 dB that rises ≥ 8 dB over the ready level and fades within 0.6 s with
  ≤ 1.5 cm and ≤ 2.5 cm/s net movement → grab; fast Doppler motion, typing, or idle → end. Holding still cycles
  dial targets every 1.6 s.
- These thresholds come from synthetic palm + finger models and a few real recordings; calibration learns the
  grab threshold from the user's own grabs.
- Volume via Core Audio on the default output (VirtualMainVolume), refusing to take the built-in speakers
  below the pilot-compensation limit. Brightness via DisplayServices (private, dlopen at runtime) with the
  NX brightness keys as fallback. Desktops via ⌃←/⌃→ with fn + number-pad flags set like real arrow keys.
