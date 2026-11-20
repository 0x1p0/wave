# M0 findings: is ultrasonic Doppler feasible on this MacBook?

2026-11-20 · MacBook Air 13" M4 (Mac16,12), macOS 27.2.1

**Short answer: yes, but only in a narrow window around 18.75–19.25 kHz.** Above ~19 kHz the
speaker→mic response collapses, and higher sample rates don't change that.

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

## Recommendations

1. **Pilot: 19 000 Hz → 18 996.1 Hz (bin-centred), 48 kHz.** 18.75 kHz is the fallback (+2–3 dB level,
   slightly more audible). Nothing ≥ 19.5 kHz is usable on this Mac.
2. **Amplitude:** at −20 dBFS and 50 % volume the Doppler margin at 19 kHz is only +8–10 dB. Because it is
   noise-limited, −8 dBFS should add ~12 dB. `make confirm` checks this (with waving) before M1.
   The earlier "try −30 dBFS" hint in the raw report came from a logic bug (since fixed).
3. **Swipes (M3) are at risk.** Two pilots must fit inside ~18.5–19.25 kHz, so they can be at most
   ~750 Hz apart. That means narrowing each Doppler band to ±250–300 Hz (≈ ±2 m/s at 19 kHz, still enough
   for hand motion) and accepting that the lower pilot is more audible. The 13" Air's left/right speakers
   are also close together. Decide after M1 shows how reliable push detection is.
4. **Volume:** the speakers' own volume matters (−18.6 dB at 50 %). With the pilot at −8 dBFS there are only
   ~8 dB of digital headroom for compensation, so M2's "Volume too low for Wave" threshold will be near 30–35 %.
