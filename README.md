# Wave

Hand gestures in the air over a MacBook, detected with ultrasonic sonar. The built-in speakers play a
tone too high to hear, the built-in microphones pick up its echo off your hand, and the Doppler shift
shows how your hand moved. No camera, no extra hardware.

You're eating, you push your hand toward the screen and back, and YouTube pauses.

| Gesture | How | Default action |
|---|---|---|
| **Push** | hand toward the screen and straight back (~0.5 s) | Play/Pause |
| **Pull** | start close, move away and straight back | nothing (map it: e.g. Minimize) |
| **Hover controls** | bring your hand up ~20 cm from the screen and hold it until ✋ appears; then **push = up, pull = down** (10 % each); hold still to switch volume ↔ brightness; move your hand away to finish | Volume, Brightness |
| **Grab** *(experimental)* | from the raised hand (✋): close it into a fist | Minimize window |
| **Swipe left / right** *(experimental, two tones)* | a brisk sideways pass 15–30 cm in front of the screen | Previous / Next track, or the **Desktops** preset |

**Learn them in the app:** menu → **Learn gestures…** opens a live, interactive tutorial that shows your
hand the way Wave senses it (toward = green, away = orange, finger motion = pink), counts each gesture and
explains why a try didn't count ("a bit slow", "didn't come back out", …). `make tutorial` installs Wave and
opens it.

Each gesture can be mapped to a media key, a window/desktop/volume/brightness action, a keyboard shortcut,
or a Shortcuts-app shortcut (Settings → Gestures).

**What's solid and what's experimental.** Push, pull and the hover controls are built on fast Doppler motion,
which real recordings on a MacBook Air M4 detect reliably (every recorded push, no false pulls or holds).
Slow sliding was dropped: real recordings showed the slow-motion echo sits only ~5–14 dB above noise.
Grab depends on faint finger motion and may not register on every Mac or hand; the tutorial's finger-motion
meter shows whether yours does. Swipes need two tones (18.75 / 19.25 kHz, one per speaker), and the 13"
Air's speakers sit close together.

## Privacy

- Audio is analysed **in memory, on your Mac**. It never leaves the Mac and is **never saved to disk**,
  except debug recordings you start yourself (debug window → Record), saved to
  `~/Library/Application Support/Wave/Recordings`.
- The **orange microphone dot** in the menu bar is on whenever Wave is listening: that's Wave hearing its
  own tone. With "Only listen while media is playing" (the default), it's off the rest of the time.
- Labeled training samples (Settings → Calibration) contain feature numbers only, never audio.

## Install and first run

Requires a MacBook (built-in speakers and microphones) with macOS 14 or later, and Xcode to build.

```sh
make install     # builds Wave.app, copies it to /Applications and starts it
```

Wave lives in the menu bar (hand icon). The first launch walks you through:

1. **Microphone** access (to hear the echo).
2. **MacBook speakers**: the tone always plays on the built-in speakers, even when you listen on
   AirPods or headphones. Your volume keys only change the device you're listening on, so the speakers
   keep their own volume. Wave compensates, and pauses with *Volume too low for Wave* when it can't
   (when the speakers are more than ~6 dB quieter than at half volume). The onboarding and menu have a
   "Set to 50 %" button.
3. **Hearing test**: if you can hear the tone, Wave moves to a higher one.
4. **Accessibility**, so Wave can press Play/Pause for you (System Settings → Privacy & Security →
   Accessibility → Wave).

Then play a video and push your hand toward the screen and back. A small confirmation appears at the
top of the screen.

**Calibrate** (menu → Calibrate…) to tune the thresholds to your room and hand: a few seconds of
stillness, then 5 pushes (and 5 swipes each way if swipes are on).

## When Wave pauses itself

Wave stops listening (and playing its tone) when:
- you typed or used the trackpad in the last 0.8 s (that gesture is ignored),
- the MacBook speakers are muted or too quiet,
- the screen is locked, the display or Mac is asleep, or the lid is closed,
- nothing is playing (with *Only listen while media is playing*), plus a grace period (default 3 min) so
  a push can resume what a push paused. If an app keeps an audio stream open while idle (Signal Desktop
  does), choose **Ignore** next to it in Settings → General.

## Troubleshooting

- **Nothing happens on a push.** Check the menu status. "Waiting for media to play" means nothing is
  playing; "Volume too low for Wave" means the MacBook speakers are too quiet. Open
  **Debug window…** to see the spectrogram and every detection with the reason it was rejected.
- **Play/Pause goes to the wrong app.** Media keys go to the system's "Now Playing" app, the one you
  played or paused most recently.
- **"Wave needs Accessibility"** after rebuilding: if Wave was ad-hoc signed (no developer certificate),
  macOS treats each build as a new app. Remove Wave from the Accessibility list and add it again. `make`
  signs with your Apple Development certificate automatically when you have one, which avoids this.
- **I can hear a faint tone.** Settings → Sound → Run hearing test, or pick a higher tone there.

## How it works

```
built-in speakers ── 19 kHz tone ──► hand ──► echo, Doppler-shifted ──► built-in mic
                                                                           │
       AUHAL capture (raw, no voice processing) → ring buffer → 4096-pt FFT every 10.7 ms
       → energy just above / below the tone vs. a still-hand baseline, Doppler speed, reference band
       → push detector: strong "toward" then "away" within 0.2–0.75 s → action
```

- **M0** measured this MacBook Air M4's speaker→mic response: usable only around 18.75–19.25 kHz (it falls
  off a cliff above ~19.5 kHz; 96 kHz sampling doesn't help). See [docs/M0-FINDINGS.md](docs/M0-FINDINGS.md).
- The tone's *acoustic* level is held constant: −8 dBFS at 50 % speaker volume, adjusted digitally as the
  speakers' own volume changes.
- **Phase tracking (hold & slide, grab).** Doppler bins are 11.7 Hz wide, so motion slower than ~0.3 m/s
  (a hand sliding a few cm/s, fingers curling) never leaves the tone's own bins. Wave also mixes each tone
  down to 0 Hz, low-passes it, subtracts the slowly varying static echo (direct path, furniture, your
  still hand), and follows the phase of what's left, the approach used by acoustic hand-tracking research
  such as LLAP. One turn of phase is one wavelength of round-trip path (1.8 cm at 19 kHz), so a few
  millimetres of hand movement are visible. Sliding keeps the moving echo strong; closing the hand makes it
  jump briefly and fade with little net movement, which is how a grab is told apart from the dial.
- **Volume** is set on the current output device through Core Audio (never below what Wave needs when you
  listen on the MacBook speakers). **Brightness** uses DisplayServices, a private Apple framework loaded at
  runtime (falls back to the brightness keys). Desktop switching sends ⌃← / ⌃→, the Mission Control
  shortcuts, which must be enabled in System Settings → Keyboard → Keyboard Shortcuts.
- **Swipes** use one tone per speaker (left 18.75 kHz, right 19.5 kHz). A hand crossing the laptop
  passes the left and right echo paths at different times; the lag between the two Doppler reversals
  separates swipes from pushes and gives the direction. This is experimental on a 13" MacBook Air (the
  speakers are close together), so calibrate after turning it on.
- Rejected gestures: recent keyboard/trackpad input (IOHIDSystem `HIDIdleTime`, no permission needed),
  broadband noise (a reference band where hand Doppler can't reach), one-way motion, too slow or fast,
  too weak.
- Power: about 2 % of one core while listening (FFT, detection, tone), nothing while idle. `make cpu`
  measures the running app.

## Building and developing

Swift 6, Apple frameworks only. `App/Wave.xcodeproj` (the app) uses the Swift package at the repository
root (`WaveCore`: audio, DSP, detection; `WaveUI`: debug views).

```sh
make app         # build Wave.app (xcodebuild)
make run         # build and launch without installing
make test        # unit tests (synthetic Doppler gestures, swipe geometry, calibration, record/replay, …)
make cpu         # CPU use of the running app
```

Tools for measuring and tuning (run them from Terminal.app, which needs microphone access):

```sh
make devices     # audio hardware report
make sweep       # M0 frequency sweep (17–22.5 kHz)
make debug       # standalone debug window: spectrogram, traces, event log
make detect      # live detection in the terminal
make record      # detection + raw audio recording for replay (LABEL=push make record)
make replay FILE=~/Library/Application\ Support/Wave/Recordings/wave-….caf
make demo        # synthetic recording with pushes, noise, typing (no waving needed)
make demo-hold   # synthetic hold & slide + grab, shown in the debug window
```

`wave-probe config > my.json` prints the detector settings; `wave-probe replay FILE --config my.json --csv
features.csv` reruns the detector on the same audio and dumps per-frame features.

### Distribution (Developer ID + notarization)

Needs a paid Apple Developer account with a **Developer ID Application** certificate. Before shipping,
change the bundle identifier (`local.wave.Wave` in the project) to one you own.

```sh
xcrun notarytool store-credentials wave-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID   # once
scripts/release.sh --team TEAMID          # archive (universal) → sign → notarize → staple → zip
```

### Layout

```
App/                   Xcode project, app sources (menu bar, settings, onboarding, calibration, HUD)
Sources/WaveCore/      Audio (Core Audio devices, AUHAL tone + capture), DSP (vDSP FFT), Detection
                       (features, push detector, two-tone fusion), Engine, Recording (CAF + replay),
                       Calibration, System (input idle, lid, media activity)
Sources/WaveUI/        Debug views (spectrogram, traces, event log)
Sources/wave-probe/    CLI: devices, speakers, sweep, live, detect, replay, config, synth, media
Sources/wave-debug/    Standalone debug window
Sources/WaveRT/        C11 atomics for the real-time audio path
Tests/                 Swift Testing unit tests
docs/                  M0 measurements, assumptions and decisions
scripts/               release (notarization), icon, CPU measurement
```
