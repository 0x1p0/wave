import Foundation
import Testing
@testable import WaveCore

@Suite("Pilot synth fades")
struct PilotSynthTests {
    let fs = 48_000.0

    private func render(_ synth: PilotSynth, frames: Int) -> [Float] {
        var left = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { synth.render(left: $0.baseAddress!, right: nil, frames: frames) }
        return left
    }

    /// Peak amplitude in a short window (envelope estimate).
    private func peak(_ x: ArraySlice<Float>) -> Float { x.map(abs).max() ?? 0 }

    @Test func fadeInTakes50msWithNoStep() {
        let synth = PilotSynth(sampleRate: fs)
        synth.update(tones: ToneSet([PilotTone(frequency: 20_000)]), amplitude: 0.5, running: true)
        let x = render(synth, frames: Int(fs * 0.1))
        #expect(abs(x[0]) < 1e-6)                                  // starts from silence
        #expect(peak(x[0..<48]) < 0.001)                            // first 1 ms is nearly silent
        #expect(peak(x[1150..<1250]) > 0.2 && peak(x[1150..<1250]) < 0.3)  // ~halfway at 25 ms
        #expect(abs(peak(x[2500..<4800]) - 0.5) < 0.01)            // full level after 50 ms
    }

    @Test func stopFadesOutAndGoesSilent() {
        let synth = PilotSynth(sampleRate: fs)
        synth.update(tones: ToneSet([PilotTone(frequency: 19_000)]), amplitude: 0.5, running: true)
        _ = render(synth, frames: 4800)
        synth.update(tones: ToneSet([PilotTone(frequency: 19_000)]), amplitude: 0.5, running: false)
        let x = render(synth, frames: 4800)
        #expect(peak(x[0..<48]) > 0.45)        // no abrupt cut
        #expect(peak(x[2400...]) == 0)         // silent after 50 ms
        #expect(synth.isSilent)
    }

    @Test func toneChangePassesThroughSilence() {
        let synth = PilotSynth(sampleRate: fs)
        synth.update(tones: ToneSet([PilotTone(frequency: 19_000)]), amplitude: 0.5, running: true)
        _ = render(synth, frames: 4800)
        synth.update(tones: ToneSet([PilotTone(frequency: 20_000)]), amplitude: 0.5, running: true)
        let x = render(synth, frames: 9600)
        let quietest = stride(from: 0, to: 9600 - 48, by: 48).map { peak(x[$0..<$0 + 48]) }.min()!
        #expect(quietest < 0.001)              // fully closed between tones
        #expect(abs(peak(x[7000..<9600]) - 0.5) < 0.01)
    }

    @Test func stereoGainsApplyPerChannel() {
        let synth = PilotSynth(sampleRate: fs)
        synth.update(
            tones: ToneSet([PilotTone(frequency: 19_000, leftGain: 1, rightGain: 0),
                            PilotTone(frequency: 20_000, leftGain: 0, rightGain: 1)]),
            amplitude: 0.25, running: true)
        let frames = 9600
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                synth.render(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames)
            }
        }
        let analyzer = SpectrumAnalyzer(fftSize: 4096, sampleRate: fs)
        var pl = [Float](), pr = [Float]()
        l.withUnsafeBufferPointer { analyzer.averagePowerSpectrum([$0.baseAddress! + 5000], into: &pl) }
        r.withUnsafeBufferPointer { analyzer.averagePowerSpectrum([$0.baseAddress! + 5000], into: &pr) }
        #expect(pl[analyzer.bin(for: 19_000)].dB > pl[analyzer.bin(for: 20_000)].dB + 60)
        #expect(pr[analyzer.bin(for: 20_000)].dB > pr[analyzer.bin(for: 19_000)].dB + 60)
    }
}

@Suite("Ring buffer")
struct RingBufferTests {
    private func write(_ ring: AudioRingBuffer, _ values: [[Float]]) {
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: values.count)
        for (i, channel) in values.enumerated() {
            ptrs[i] = .allocate(capacity: channel.count)
            ptrs[i].initialize(from: channel, count: channel.count)
        }
        ring.write(ptrs, frames: values[0].count)
        for i in values.indices { ptrs[i].deallocate() }
        ptrs.deallocate()
    }

    @Test func roundTripAcrossWrap() {
        let ring = AudioRingBuffer(channels: 2, minimumCapacity: 1000)  // → 1024
        var expected: [Float] = []
        var got: [Float] = []
        var next: Float = 0
        for _ in 0..<20 {
            let chunk = (0..<300).map { _ in next += 1; return next }
            expected += chunk
            write(ring, [chunk, chunk.map { -$0 }])
            let out = ring.readAvailable()
            #expect(out[1] == out[0].map { -$0 })
            got += out[0]
        }
        #expect(got == expected)
        #expect(ring.droppedFrames == 0)
    }

    @Test func overrunSkipsAhead() {
        let ring = AudioRingBuffer(channels: 1, minimumCapacity: 1024)
        for i in 0..<5 { write(ring, [[Float](repeating: Float(i), count: 512)]) }
        let out = ring.readAvailable()[0]
        #expect(out.count == 512)            // jumped to the latest half-buffer
        #expect(out.allSatisfy { $0 == 4 })
        #expect(ring.droppedFrames == 2048)
    }
}
