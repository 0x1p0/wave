import Foundation
import Testing
@testable import WaveCore

@Suite("Spectrum analysis")
struct SpectrumTests {
    let fs = 48_000.0
    let n = 4096

    @Test func fullScaleBinCentredSineReadsZeroDBFS() {
        let analyzer = SpectrumAnalyzer(fftSize: n, sampleRate: fs)
        let f = analyzer.snapped(20_000)
        let x = SyntheticSignal.tone(frequency: f, amplitude: 1, sampleRate: fs, count: n, phase: 0.3)
        var p = [Float]()
        x.withUnsafeBufferPointer { analyzer.averagePowerSpectrum([$0.baseAddress!], into: &p) }
        #expect(abs(p[analyzer.bin(for: f)].dB) < 0.01)
    }

    @Test func levelTracksAmplitude() {
        let analyzer = SpectrumAnalyzer(fftSize: n, sampleRate: fs)
        let f = analyzer.snapped(19_000)
        let x = SyntheticSignal.tone(frequency: f, amplitude: 0.01, sampleRate: fs, count: n)  // −40 dBFS
        var p = [Float]()
        x.withUnsafeBufferPointer { analyzer.averagePowerSpectrum([$0.baseAddress!], into: &p) }
        #expect(abs(p[analyzer.bin(for: f)].dB - -40) < 0.01)
    }

    @Test func binCentredPilotDoesNotLeakIntoSidebands() {
        let analyzer = SpectrumAnalyzer(fftSize: n, sampleRate: fs)
        let band = PilotBand(pilotHz: 20_000, binWidth: analyzer.binWidth)
        let x = SyntheticSignal.tone(frequency: band.pilotHz, amplitude: 0.5, sampleRate: fs, count: n)
        var p = [Float]()
        x.withUnsafeBufferPointer { analyzer.averagePowerSpectrum([$0.baseAddress!], into: &p) }
        let frame = band.measure(p)
        // Sidebands should be > 100 dB below the pilot (only float rounding remains).
        #expect(frame.upperEnergy.dB < frame.pilotPower.dB - 100)
        #expect(frame.lowerEnergy.dB < frame.pilotPower.dB - 100)
    }

    @Test func multichannelAverage() {
        let analyzer = SpectrumAnalyzer(fftSize: n, sampleRate: fs)
        let f = analyzer.snapped(21_000)
        let a = SyntheticSignal.tone(frequency: f, amplitude: 1, sampleRate: fs, count: n)
        let b = [Float](repeating: 0, count: n)
        var p = [Float]()
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                analyzer.averagePowerSpectrum([pa.baseAddress!, pb.baseAddress!], into: &p)
            }
        }
        #expect(abs(p[analyzer.bin(for: f)].dB - -3.0103) < 0.01)  // half the power
    }
}

@Suite("Pilot band / Doppler")
struct PilotBandTests {
    let fs = 48_000.0
    let n = 4096

    @Test func velocityMapping() {
        let band = PilotBand(pilotHz: 20_000, binWidth: fs / Double(n))
        // 0.5 m/s toward → Δf = 2·v·f/c ≈ 58.3 Hz
        let shift = 2 * 0.5 * band.pilotHz / PilotBand.speedOfSound
        #expect(abs(band.velocity(forShift: shift) - 0.5) < 1e-9)
    }

    @Test(arguments: [0.6, -0.6])
    func reflectionLandsInTheRightSideband(velocity: Double) {
        let analyzer = SpectrumAnalyzer(fftSize: n, sampleRate: fs)
        let band = PilotBand(pilotHz: 20_000, binWidth: analyzer.binWidth)
        let direct = SyntheticSignal.tone(frequency: band.pilotHz, amplitude: 0.1, sampleRate: fs, count: n)
        let echo = SyntheticSignal.reflection(
            pilot: band.pilotHz, amplitude: 0.001, sampleRate: fs, count: n) { _ in velocity }
        let noise = SyntheticSignal.noise(rms: 1e-5, count: n)
        let x = SyntheticSignal.mix(direct, echo, noise)
        var p = [Float]()
        x.withUnsafeBufferPointer { analyzer.averagePowerSpectrum([$0.baseAddress!], into: &p) }
        let frame = band.measure(p)
        if velocity > 0 {
            #expect(frame.upperEnergy.dB > frame.lowerEnergy.dB + 20)
        } else {
            #expect(frame.lowerEnergy.dB > frame.upperEnergy.dB + 20)
        }
        // Peak sideband bin matches the expected shift (±1 bin).
        let expectedOffset = 2 * velocity * band.pilotHz / PilotBand.speedOfSound / band.binWidth
        let range = velocity > 0 ? band.upperRange : band.lowerRange
        let peak = range.max { p[$0] < p[$1] }!
        #expect(abs(Double(peak - band.pilotBin) - expectedOffset) <= 1)
    }

    @Test func stats() {
        #expect(Stats.median([3, 1, 2]) == 2)
        #expect(Stats.median([4, 1, 2, 3]) == 2.5)
        #expect(Stats.percentile(Array(1...100).map(Float.init), 0.95) == 95)
    }
}

@Suite("Frame slicer")
struct FrameSlicerTests {
    @Test func emitsOneWindowPerHopAfterWarmUp() {
        let slicer = FrameSlicer(channels: 1, fftSize: 4096, hop: 512)
        var count = 0
        slicer.push([[Float](repeating: 0, count: 4096 + 10 * 512)]) { _ in count += 1 }
        #expect(count == 11)
    }

    @Test func chunkingDoesNotChangeWindows() {
        let signal = (0..<9000).map { Float($0) }
        func windows(chunk: Int) -> [[Float]] {
            let slicer = FrameSlicer(channels: 2, fftSize: 1024, hop: 256)
            var out = [[Float]]()
            var i = 0
            while i < signal.count {
                let part = Array(signal[i..<min(signal.count, i + chunk)])
                slicer.push([part, part.map { -$0 }]) { w in
                    out.append(Array(UnsafeBufferPointer(start: w[0], count: 1024)))
                    #expect(w[1][5] == -w[0][5])
                }
                i += chunk
            }
            return out
        }
        let a = windows(chunk: 9000)
        let b = windows(chunk: 97)
        #expect(a == b)
        #expect(a.first?.first == 0)
        #expect(a.last?.last == Float(1024 + (a.count - 1) * 256 - 1))
    }

    @Test func resetDropsHistory() {
        let slicer = FrameSlicer(channels: 1, fftSize: 1024, hop: 256)
        var count = 0
        slicer.push([[Float](repeating: 1, count: 1024)]) { _ in count += 1 }
        slicer.reset()
        slicer.push([[Float](repeating: 2, count: 768)]) { _ in count += 1 }
        #expect(count == 1)  // needs a full 1024 new samples after reset
    }
}
