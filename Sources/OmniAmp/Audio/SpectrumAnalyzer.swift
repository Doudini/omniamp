import Accelerate
import AVFoundation

/// Computes ~20 log-spaced bars from the output tap. Thread-safe snapshot via lock.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let barCount = 20
    private let n = 2048
    private let log2n: vDSP_Length
    private let fft: FFTSetup
    private var window: [Float]
    private let lock = NSLock()
    private var latest = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)

    init() {
        log2n = vDSP_Length(log2(Double(n)))
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    func reset() {
        lock.lock(); latest = [Float](repeating: 0, count: Self.barCount); lock.unlock()
    }

    /// Latest bar levels in 0...1.
    func bars() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let sampleRate = Float(buffer.format.sampleRate)

        // Mono mix, zero-padded to n.
        var mono = [Float](repeating: 0, count: n)
        let count = min(frames, n)
        let channels = Int(buffer.format.channelCount)
        for c in 0..<channels {
            vDSP_vadd(mono, 1, ch[c], 1, &mono, 1, vDSP_Length(count))
        }
        var scale = 1 / Float(max(channels, 1))
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))
        vDSP_vmul(mono, 1, window, 1, &mono, 1, vDSP_Length(n))

        let half = n / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                mono.withUnsafeBufferPointer { mp in
                    mp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        // Log-spaced bands 40 Hz ... 16 kHz.
        let binHz = sampleRate / Float(n)
        let lo: Float = 40, hi: Float = min(16000, sampleRate / 2)
        var out = [Float](repeating: 0, count: Self.barCount)
        for b in 0..<Self.barCount {
            let f0 = lo * powf(hi / lo, Float(b) / Float(Self.barCount))
            let f1 = lo * powf(hi / lo, Float(b + 1) / Float(Self.barCount))
            let i0 = max(1, Int(f0 / binHz))
            let i1 = min(half - 1, max(i0 + 1, Int(f1 / binHz)))
            var peak: Float = 0
            for i in i0..<i1 { peak = max(peak, mags[i]) }
            // Normalise: dB over a ~60 dB range.
            let db = 20 * log10f(peak / Float(n) * 4 + 1e-9)
            out[b] = max(0, min(1, (db + 60) / 60))
        }
        lock.lock(); latest = out; lock.unlock()
    }
}
