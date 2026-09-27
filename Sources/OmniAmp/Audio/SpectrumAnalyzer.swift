import Accelerate
import AVFoundation
import os

/// Computes ~20 log-spaced bars from the output tap.
///
/// Runs on the audio thread, so it never allocates there: all buffers are created once. When no analyzer is
/// visible (`isEnabled == false`) it returns immediately, so hidden playback costs nothing extra.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let barCount = 20
    private let n = 2048
    private let log2n: vDSP_Length
    private let fft: FFTSetup
    private var window: [Float]
    private var mono: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var work: [Float]
    /// Precomputed FFT bin ranges per bar for the current sample rate.
    private var bands: [(Int, Int)] = []
    private var bandsRate: Float = 0
    private let latest = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: SpectrumAnalyzer.barCount))
    private let enabledFlag = OSAllocatedUnfairLock(initialState: false)
    /// Oscilloscope: 128 mono samples of the latest buffer (-1…1).
    static let waveCount = 128
    private var waveWork = [Float](repeating: 0, count: SpectrumAnalyzer.waveCount)
    private let latestWave = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: SpectrumAnalyzer.waveCount))
    /// Left/right peak level of the latest buffer, 0...1 over a 40 dB range (for the level meters).
    private let latestLevels = OSAllocatedUnfairLock(initialState: (Float(0), Float(0)))

    /// Turned on only while an analyzer is on screen and music plays.
    var isEnabled: Bool {
        get { enabledFlag.withLock { $0 } }
        set { enabledFlag.withLock { $0 = newValue } }
    }

    init() {
        log2n = vDSP_Length(log2(Double(n)))
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        mono = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        mags = [Float](repeating: 0, count: n / 2)
        work = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    func reset() {
        latest.withLock { for i in $0.indices { $0[i] = 0 } }
        latestWave.withLock { for i in $0.indices { $0[i] = 0 } }
        latestLevels.withLock { $0 = (0, 0) }
    }

    /// Latest left/right levels in 0...1 (-40 dB ... 0 dB).
    func levels() -> (left: Float, right: Float) { latestLevels.withLock { $0 } }

    static func meterLevel(_ peak: Float) -> Float {
        let db = 20 * log10f(max(peak, 1e-6))
        return max(0, min(1, (db + 40) / 40))
    }

    /// Latest waveform for the oscilloscope.
    func wave() -> [Float] { latestWave.withLock { $0 } }

    /// Latest bar levels in 0...1.
    func bars() -> [Float] { latest.withLock { $0 } }

    private func updateBands(_ sampleRate: Float) {
        let half = n / 2
        let binHz = sampleRate / Float(n)
        let lo: Float = 40, hi: Float = min(16000, sampleRate / 2)
        bands = (0..<Self.barCount).map { b in
            let f0 = lo * powf(hi / lo, Float(b) / Float(Self.barCount))
            let f1 = lo * powf(hi / lo, Float(b + 1) / Float(Self.barCount))
            let i0 = max(1, Int(f0 / binHz))
            return (i0, min(half - 1, max(i0 + 1, Int(f1 / binHz))))
        }
        bandsRate = sampleRate
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled, let ch = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let sampleRate = Float(buffer.format.sampleRate)
        if sampleRate != bandsRate { updateBands(sampleRate) }

        // Mono mix of up to n frames, zero-padded.
        let count = min(frames, n)
        let channels = Int(buffer.format.channelCount)
        // Level meters: each channel's peak (mono feeds both).
        var pl: Float = 0, pr: Float = 0
        vDSP_maxmgv(ch[0], 1, &pl, vDSP_Length(frames))
        if channels > 1 { vDSP_maxmgv(ch[1], 1, &pr, vDSP_Length(frames)) } else { pr = pl }
        let lv = (Self.meterLevel(pl), Self.meterLevel(pr))
        latestLevels.withLock { $0 = lv }
        vDSP_vclr(&mono, 1, vDSP_Length(n))
        for c in 0..<channels { vDSP_vadd(mono, 1, ch[c], 1, &mono, 1, vDSP_Length(count)) }
        var scale = 1 / Float(max(channels, 1))
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))
        // Oscilloscope: pick evenly spaced samples before windowing.
        let step = max(1, count / Self.waveCount)
        for i in 0..<Self.waveCount { waveWork[i] = mono[min(count - 1, i * step)] }
        latestWave.withLock { for i in 0..<Self.waveCount { $0[i] = waveWork[i] } }
        vDSP_vmul(mono, 1, window, 1, &mono, 1, vDSP_Length(n))

        let half = n / 2
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

        for (b, (i0, i1)) in bands.enumerated() {
            var peak: Float = 0
            for i in i0..<i1 where mags[i] > peak { peak = mags[i] }
            // Normalise: dB over a ~60 dB range.
            let db = 20 * log10f(peak / Float(n) * 4 + 1e-9)
            work[b] = max(0, min(1, (db + 60) / 60))
        }
        // Element-wise copy: the locked array stays uniquely owned, so this never allocates.
        latest.withLock { for i in 0..<Self.barCount { $0[i] = work[i] } }
    }
}
