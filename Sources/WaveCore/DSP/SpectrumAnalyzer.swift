import Accelerate
import Foundation

/// Hann-windowed real FFT (vDSP) producing a one-sided power spectrum normalised so that a
/// full-scale sine exactly on a bin centre reads 1.0 (0 dBFS) in that bin.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let sampleRate: Double
    public var binCount: Int { fftSize / 2 }
    public var binWidth: Double { sampleRate / Double(fftSize) }

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private let normalization: Float

    public init(fftSize: Int = 4096, sampleRate: Double) {
        precondition(fftSize >= 64 && fftSize & (fftSize - 1) == 0, "fftSize must be a power of two")
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: fftSize)
        vDSP_hann_window(window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        windowed = .allocate(capacity: fftSize)
        real = .allocate(capacity: fftSize / 2)
        imag = .allocate(capacity: fftSize / 2)
        scratch = .allocate(capacity: fftSize / 2)
        var sum: Float = 0
        vDSP_sve(window, 1, &sum, vDSP_Length(fftSize))
        // vDSP_fft_zrip output is 2x the DFT; |2·X_k| = A·Σw for a bin-centred sine of amplitude A.
        normalization = 1 / (sum * sum)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate(); windowed.deallocate()
        real.deallocate(); imag.deallocate(); scratch.deallocate()
    }

    public func bin(for frequency: Double) -> Int { Int((frequency / binWidth).rounded()) }
    public func frequency(ofBin bin: Int) -> Double { Double(bin) * binWidth }

    /// Snaps a frequency to the nearest bin centre so a steady pilot leaks as little as possible.
    public func snapped(_ frequency: Double) -> Double { self.frequency(ofBin: bin(for: frequency)) }

    /// Power spectrum of `input` (fftSize samples). If `accumulate` is true the result is added to `output`.
    public func powerSpectrum(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>, accumulate: Bool = false) {
        let n = vDSP_Length(fftSize)
        let half = vDSP_Length(fftSize / 2)
        vDSP_vmul(input, 1, window, 1, windowed, 1, n)
        var split = DSPSplitComplex(realp: real, imagp: imag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
            vDSP_ctoz($0, 2, &split, 1, half)
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        // Bin 0 packs DC (real) and Nyquist (imag); we never look there, just zero Nyquist.
        imag[0] = 0
        var scale = normalization
        if accumulate {
            vDSP_zvmags(&split, 1, scratch, 1, half)
            vDSP_vsma(scratch, 1, &scale, output, 1, output, 1, half)
        } else {
            vDSP_zvmags(&split, 1, output, 1, half)
            vDSP_vsmul(output, 1, &scale, output, 1, half)
        }
    }

    /// Mean power spectrum across channels (incoherent average). `channels[i]` must hold fftSize samples.
    public func averagePowerSpectrum(_ channels: [UnsafePointer<Float>], into output: inout [Float]) {
        if output.count != binCount { output = [Float](repeating: 0, count: binCount) }
        output.withUnsafeMutableBufferPointer { out in
            for (i, ch) in channels.enumerated() {
                powerSpectrum(ch, into: out.baseAddress!, accumulate: i > 0)
            }
            if channels.count > 1 {
                var inv = 1 / Float(channels.count)
                vDSP_vsmul(out.baseAddress!, 1, &inv, out.baseAddress!, 1, vDSP_Length(binCount))
            }
        }
    }
}

public extension Float {
    /// Power ratio → decibels, floored at -200 dB.
    var dB: Float { 10 * log10(Swift.max(self, 1e-20)) }
}

public extension Double {
    var dB: Double { 10 * log10(Swift.max(self, 1e-20)) }
}
