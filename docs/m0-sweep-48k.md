# Wave M0 — ultrasonic feasibility probe

Run 2026-11-20T10:51:27Z

| | |
|---|---|
| Machine | MacBook Air (Mac16,12, Apple M4), macOS 27.2.1 (26B131) |
| Pilot output | MacBook Air Speakers — 2 ch @ 48000 Hz, volume 50% (-18.6 dB) |
| Capture | MacBook Air Microphone — **1 ch** @ 48000 Hz (supported rates: **44100, 48000, 88200, 96000**), mic mode Standard |
| Pilot amplitude | -20.0 dBFS digital, 50 ms raised-cosine fades, both channels |
| Analysis | Hann, FFT 4096, hop 512 (11.72 Hz bins, 10.7 ms hop) |
| Doppler band | pilot ± 3…32 bins = ± 35–375 Hz |
| Dropped frames | 0 |

## Results

| Freq Hz | Pilot Hz | Level dBFS | Noise dB/bin | SNR dB | Skirt dB/bin | ▲ toward dB | ▼ away dB | Doppler visible |
|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| 17000 | 17003.9 | -54.9 | -119.3 | 64.4 | -103.7 | +22.3 | +19.6 | y |
| 17250 | 17250.0 | -56.0 | -119.5 | 63.5 | -105.5 | +21.2 | +19.1 | y |
| 17500 | 17496.1 | -59.7 | -119.6 | 59.9 | -107.6 | +14.5 | +15.9 | y |
| 17750 | 17753.9 | -61.2 | -119.0 | 57.8 | -109.6 | +11.4 | +13.7 | y |
| 18000 | 18000.0 | -67.3 | -119.2 | 51.9 | -111.6 | +15.8 | +11.7 | y |
| 18250 | 18246.1 | -64.5 | -118.8 | 54.4 | -113.3 | +16.1 | +14.7 | y |
| 18500 | 18503.9 | -66.1 | -117.8 | 51.6 | -114.2 | +2.2 | +5.5 | n |
| 18750 | 18750.0 | -71.3 | -121.0 | 49.7 | -116.6 | +12.3 | +6.0 | y |
| 19000 | 18996.1 | -73.7 | -120.4 | 46.8 | -117.4 | +9.6 | +7.9 | y |
| 19250 | 19253.9 | -80.1 | -121.1 | 41.1 | -118.2 | +5.5 | +3.7 | n |
| 19500 | 19500.0 | -83.6 | -120.9 | 37.3 | -118.3 | +2.2 | +3.1 | n |
| 19750 | 19746.1 | -90.9 | -120.6 | 29.7 | -119.2 | +3.0 | +1.7 | n |
| 20000 | 20003.9 | -99.0 | -120.9 | 21.9 | -121.1 | +1.8 | +2.7 | n |
| 20250 | 20250.0 | -103.2 | -121.3 | 18.1 | -121.4 | +1.7 | +1.7 | n |
| 20500 | 20496.1 | -108.2 | -120.8 | 12.6 | -121.1 | +1.4 | +0.8 | n |
| 20750 | 20753.9 | -115.9 | -120.8 | 4.9 | -120.8 | +1.4 | +2.0 | n |
| 21000 | 21000.0 | -118.9 | -120.9 | 2.0 | -120.5 | +2.6 | +2.3 | n |
| 21250 | 21246.1 | -120.2 | -120.3 | 0.2 | -120.6 | +2.4 | +1.8 | n |
| 21500 | 21503.9 | -120.8 | -120.4 | -0.4 | -120.2 | +11.8 | +11.5 | y |
| 21750 | 21750.0 | -119.4 | -120.4 | 1.1 | -120.2 | -0.4 | +1.2 | n |
| 22000 | 21996.1 | -120.6 | -119.9 | -0.7 | -119.8 | +2.1 | +1.6 | n |
| 22250 | 22253.9 | -120.6 | -119.6 | -1.1 | -119.6 | +1.2 | +1.6 | n |
| 22500 | 22500.0 | -118.0 | -119.6 | 1.6 | -120.3 | +1.7 | +1.9 | n |

## Verdict

**FEASIBLE: the speakers and mic carry 18+ kHz cleanly and a waving hand shows clear Doppler sidebands.**

- Primary pilot (push detection): 19000 Hz → 18996.09 Hz bin-centred (SNR 46.8 dB, Doppler ≥ +7.9 dB).
- No second usable frequency ≥ 1 kHz away from the first: two-pilot swipes (M3) look doubtful.
- Amplitude: the sideband floor is above the noise floor (speaker/mic distortion), so lowering the pilot won't cost much Doppler visibility; try ≈ -30 dBFS in M1.
- 17–18.5 kHz also works acoustically but is audible to many people (especially younger listeners), so it is excluded.
- Unusable (SNR < 10 dB): 20750, 21000, 21250, 21500, 21750, 22000, 22250, 22500 Hz.

## Columns

- **Level** — power in the pilot's own FFT bin, pilot on, hands still (0 dBFS = full-scale sine).
- **Noise** — median per-bin power across the Doppler band with the pilot **off**.
- **SNR** — Level − Noise.
- **Skirt** — median per-bin power across the Doppler band with the pilot **on**, hands still. If it is well above Noise, the speaker/mic chain adds distortion or phase noise around the pilot that Doppler has to beat.
- **▲ / ▼** — 95th-percentile sideband energy while waving vs the still-hand mean, above (toward) and below (away) the pilot.
- **Doppler visible** — y when both ▲ and ▼ are ≥ +6 dB.
