# Wave M0 — ultrasonic feasibility probe

Run 2026-11-20T11:01:27Z

| | |
|---|---|
| Machine | MacBook Air (Mac16,12, Apple M4), macOS 27.2.1 (26B131) |
| Pilot output | MacBook Air Speakers — 2 ch @ 48000 Hz, volume 50% (-18.6 dB) |
| Capture | MacBook Air Microphone — **1 ch** @ 48000 Hz (supported rates: **44100, 48000, 88200, 96000**), mic mode Standard |
| Pilot amplitude | -8.0 dBFS digital, 50 ms raised-cosine fades, both channels |
| Analysis | Hann, FFT 4096, hop 512 (11.72 Hz bins, 10.7 ms hop) |
| Doppler band | pilot ± 3…32 bins = ± 35–375 Hz |
| Dropped frames | 0 |

## Results

| Freq Hz | Pilot Hz | Level dBFS | Noise dB/bin | SNR dB | Skirt dB/bin | ▲ toward dB | ▼ away dB | Doppler visible |
|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| 18500 | 18503.9 | -55.9 | -117.8 | 61.9 | -111.2 | +15.2 | +6.4 | y (weak) |
| 18750 | 18750.0 | -60.5 | -120.6 | 60.1 | -113.5 | +20.7 | +18.5 | y |
| 19000 | 18996.1 | -66.4 | -121.3 | 54.9 | -115.7 | +14.2 | +16.1 | y |
| 19250 | 19253.9 | -71.4 | -121.1 | 49.7 | -117.0 | +13.8 | +17.3 | y |
| 19500 | 19500.0 | -75.9 | -120.6 | 44.7 | -117.7 | +9.8 | +12.1 | y (weak) |

## Verdict

**FEASIBLE: the speakers and mic carry 18+ kHz cleanly and a waving hand shows clear Doppler sidebands.**

- Primary pilot (push detection): 18750 Hz → 18750.00 Hz bin-centred (SNR 60.1 dB, Doppler ≥ +18.5 dB).
- Stereo pair for swipes (M3): left 18500 Hz, right 19500 Hz (≥ 1 kHz apart so Doppler bands can't overlap).
- Amplitude: the sideband floor is set by the speaker/mic chain (it rises with the pilot), so level changes barely affect Doppler visibility; Doppler margin +18.5 dB.

## Columns

- **Level** — power in the pilot's own FFT bin, pilot on, hands still (0 dBFS = full-scale sine).
- **Noise** — median per-bin power across the Doppler band with the pilot **off**.
- **SNR** — Level − Noise.
- **Skirt** — median per-bin power across the Doppler band with the pilot **on**, hands still. If it is well above Noise, the speaker/mic chain adds distortion or phase noise around the pilot that Doppler has to beat.
- **▲ / ▼** — 95th-percentile sideband energy while waving vs the still-hand mean, above (toward) and below (away) the pilot.
- **Doppler visible** — y when both ▲ and ▼ are ≥ +10 dB, "y (weak)" for +6…10 dB. Requires SNR ≥ 10 dB; `n*` = sidebands rose without a usable pilot (broadband noise during waving, not Doppler).
