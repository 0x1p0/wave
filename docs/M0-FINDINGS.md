# M0 findings: is ultrasonic Doppler feasible on this MacBook?

2026-11-20 · MacBook Air 13" M4 (Mac16,12), macOS 27.2.1

**Short answer: yes.** It works in a narrow window, ~18.75–19.25 kHz, with the pilot at about −8 dBFS
(speakers at 50 %). Above ~19.5 kHz the speaker→mic response collapses, and higher sample rates don't
change that.

## Hardware

| | |
|---|---|
| Mic | `MacBook Air Microphone`: **1 channel** (the array is beamformed before Core Audio sees it); 44.1 / 48 / 88.2 / 96 kHz |
| Speakers | `MacBook Air Speakers`: 2 channels; 44.1 / 48 / 88.2 / 96 kHz |
| Test conditions | speakers' own volume 50 % (−18.6 dB), pilot −20 dBFS, mic gain 53 %, mic mode Standard |

## Sweep at 48 kHz (raw: [m0-sweep-48k.md](m0-sweep-48k.md))

| Pilot | Level dBFS | SNR dB | Doppler ▲ / ▼ dB (waving vs still) | |
|---:|---:|---:|---:|---|
| 17.0 kHz | −54.9 | 64 | +22 / +20 | strong, but audible to many |
| 18.0 kHz | −67.3 | 52 | +16 / +12 | strong, possibly audible |
| 18.5 kHz | −66.1 | 52 | +2 / +6 | (outlier: hand probably paused) |
| 18.75 kHz | −71.3 | 50 | +12 / +6 | usable |
| **19.0 kHz** | **−73.7** | **47** | **+10 / +8** | **usable, thin margin** |
| 19.25 kHz | −80.1 | 41 | +6 / +4 | too weak at −20 dBFS |
| 19.5 kHz | −83.6 | 37 | +2 / +3 | no Doppler |
| 20.0 kHz | −99.0 | 22 | +2 / +3 | no Doppler |
| ≥ 20.75 kHz | noise | < 5 | | nothing gets through |

- The received pilot falls ~25–30 dB per kHz above 19 kHz. Something in the speaker/mic chain (driver
  response, speaker-protection DSP or the mic array's processing) low-passes at about 19 kHz.
- At 19 kHz the still-hand sideband floor is only ~3 dB above the noise floor, so detection is
  **noise-limited**: Doppler visibility scales 1:1 with pilot level. A louder pilot should help directly.
- The "y" at 21.5 kHz in the raw report is not Doppler: there is no pilot there (SNR −0.4 dB). Broadband
  noise during waving (clothing, rings…) raised the sidebands. The detector needs a reference band away
  from the pilot to reject these bursts. The probe now marks such rows `n*`.
- Repeatability: an independent still-hand run (Claude, same afternoon) matched within ~1 dB.

## Sample rate: 96 kHz doesn't help

Still-hand pilot level (dBFS), 18.5–22.5 kHz runs:

| mic / speakers | 19.0 kHz | 19.5 kHz | 20.0 kHz | 20.5 kHz | 21.0 kHz |
|---|---:|---:|---:|---:|---:|
| 48k / 48k | −73.5 | −82.8 | −97.7 | −108.1 | noise |
| 96k / 48k | −74.6 | −83.8 | −97.7 | −108.1 | noise |
| 96k / 96k | −73.8 | −83.0 | −98.7 | −108.0 | noise |

- Identical roll-off, so the limit is the hardware/DSP, not the 48 kHz anti-alias filter.
- At 96 kHz the mic path is also hard-limited at ~21.7 kHz (the noise floor drops to −180 dB above it).
- One run that started right after back-to-back rate switches captured near-silence for its whole
  duration. Device rate changes are asynchronous and can leave a new capture silently dead.
- **Decision:** run at 48 kHz, never change device sample rates, and treat a mic that goes silent as a fault.

## Louder pilot: −20 → −8 dBFS (raw: [m0-sweep-19k-loud.md](m0-sweep-19k-loud.md))

| Pilot | Level −20 dBFS | Level −8 dBFS | Doppler ▲/▼ at −20 | Doppler ▲/▼ at −8 |
|---:|---:|---:|---:|---:|
| 18.5 kHz | −66.1 | −55.9 (+10.2) | +2 / +6 | +15 / +6 (weak) |
| 18.75 kHz | −71.3 | −60.5 (+10.8) | +12 / +6 | **+21 / +19** |
| 19.0 kHz | −73.7 | −66.4 (+7.3) | +10 / +8 | **+14 / +16** |
| 19.25 kHz | −80.1 | −71.4 (+8.7) | +6 / +4 | **+14 / +17** |
| 19.5 kHz | −83.6 | −75.9 (+7.7) | +2 / +3 | +10 / +12 (weak) |

- 12 dB more drive bought only 7–11 dB more received level. The speaker chain is probably starting to
  compress (speaker protection) near 19 kHz, so going louder than −8 dBFS has diminishing returns.
- Doppler margin improved by 6–13 dB, and 19.0–19.25 kHz now has a comfortable +14 dB or more.
- 18.5 kHz is oddly weak on the "away" side in both runs. It's below the recommended range anyway.

## Recommendations

1. **Run at 48 kHz.** Never change device sample rates (see above).
2. **Default pilot: 19 000 Hz → 18 996.1 Hz (bin-centred), −8 dBFS at 50 % speaker volume** (+14/+16 dB
   Doppler). 18.75 kHz has the most margin (+19 dB) but is more audible. 19.25 kHz works as well as
   19.0 kHz, so the M5 "can you hear the tone?" test has a real higher fallback: 19.0 → 19.25 kHz.
3. **Volume compensation (M2):** the reference drive is −8 dBFS at a device gain of −18.6 dB (50 %), about
   −26.6 dB overall. Digital compensation can add ~6 dB (up to −2 dBFS), so Wave should pause with "Volume too
   low for Wave" when the speakers' gain drops below about −24.6 dB. Use the device's dB value, not the slider %.
4. **Detector (M1):** reject broadband bursts with a reference band away from the pilot (see the 21.5 kHz `n*`).
   At 19 kHz the sideband floor is partly set by the speaker/mic chain, so thresholds must be relative to
   the measured still-hand floor, not absolute.
5. **Swipes (M3) remain at risk.** The probe's mechanical pick (18.5 + 19.5 kHz) uses the two weakest usable
   tones, and in stereo each tone comes from one side only (less level). 18.75 kHz left + 19.5 kHz right
   (750 Hz apart, Doppler bands narrowed to ±300 Hz) is the more realistic pair. Decide after M1.
