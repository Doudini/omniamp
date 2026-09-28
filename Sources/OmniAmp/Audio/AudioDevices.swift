import CoreAudio
import Foundation

/// An output device as seen by the Core Audio HAL.
struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    /// Discrete nominal sample rates the device supports.
    let rates: [Double]
}

/// Thin wrapper around the Core Audio HAL for output devices: listing, sample rate, hog mode, hardware volume.
enum AudioDevices {
    private static let commonRates: [Double] = [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000,
                                                176_400, 192_000, 352_800, 384_000, 705_600, 768_000]

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func get<T: BitwiseCopyable>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func getArray<T: BitwiseCopyable>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ zero: T) -> [T] {
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var arr = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        let status = arr.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return arr
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &s) == noErr, let v = s else { return nil }
        return v.takeRetainedValue() as String
    }

    // MARK: Devices

    static func outputDevices() -> [AudioDevice] {
        let ids = getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), AudioDeviceID(0))
        return ids.compactMap { id in
            let streams = getArray(id, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID(0))
            guard !streams.isEmpty, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, rates: availableRates(id))
        }
    }

    static func defaultOutputID() -> AudioDeviceID {
        get(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0
    }

    static func device(uid: String) -> AudioDevice? { outputDevices().first { $0.uid == uid } }
    static func device(id: AudioDeviceID) -> AudioDevice? { outputDevices().first { $0.id == id } }

    // MARK: Sample rate

    static func availableRates(_ id: AudioDeviceID) -> [Double] {
        let ranges = getArray(id, address(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange())
        var out = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { out.insert(r.mMinimum) }
            else { commonRates.filter { $0 >= r.mMinimum && $0 <= r.mMaximum }.forEach { out.insert($0) } }
        }
        return out.sorted()
    }

    static func nominalRate(_ id: AudioDeviceID) -> Double {
        get(id, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
    }

    /// The rate to use for a file: exact match, else the best multiple of the file's rate family, else the highest.
    static func bestRate(for fileRate: Double, supported: [Double]) -> Double? {
        guard !supported.isEmpty else { return nil }
        if supported.contains(fileRate) { return fileRate }
        // Same family (44.1k multiples vs 48k multiples) avoids fractional resampling.
        let family = supported.filter { $0 > fileRate && $0.truncatingRemainder(dividingBy: fileRate) == 0 }
        if let f = family.first { return f }
        return supported.first { $0 > fileRate } ?? supported.last
    }

    /// Sets the nominal rate and waits (up to ~1 s) until the hardware reports it.
    @discardableResult
    static func setNominalRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        if nominalRate(id) == rate { return true }
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var r = Float64(rate)
        guard AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &r) == noErr else { return false }
        for _ in 0..<100 {
            if nominalRate(id) == rate { return true }
            usleep(10_000)
        }
        return nominalRate(id) == rate
    }

    // MARK: IO buffer size

    /// Ask for large IO buffers (per-process setting): fewer wakeups per second = less energy.
    /// A player doesn't need low latency; ~85 ms at 48 kHz is still instant for play/pause/seek.
    static func setIOBufferFrames(_ id: AudioDeviceID, _ frames: UInt32) {
        let range = get(id, address(kAudioDevicePropertyBufferFrameSizeRange), AudioValueRange())
        let f = UInt32(min(Double(frames), range?.mMaximum ?? Double(frames)))
        var a = address(kAudioDevicePropertyBufferFrameSize)
        var v = f
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    /// Bits per sample the device's output stream really takes (its physical format): a file with more is
    /// truncated on the way. A float stream holds 24-bit samples exactly. nil if the device won't say.
    static func outputBitDepth(_ id: AudioDeviceID) -> Int? {
        let streams = getArray(id, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID(0))
        guard let s = streams.first,
              let f = get(s, address(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription()), f.mBitsPerChannel > 0
        else { return nil }
        return f.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? 24 : Int(f.mBitsPerChannel)
    }

    // MARK: Hog mode (exclusive access)

    static func hogOwner(_ id: AudioDeviceID) -> pid_t {
        get(id, address(kAudioDevicePropertyHogMode), pid_t(-1)) ?? -1
    }

    /// Take (or release) exclusive access. The property toggles, so only write when it needs to change.
    @discardableResult
    static func setHog(_ id: AudioDeviceID, _ on: Bool) -> Bool {
        let me = getpid()
        let owner = hogOwner(id)
        if on == (owner == me) { return true }
        if on && owner != -1 { return false } // someone else owns it
        var a = address(kAudioDevicePropertyHogMode)
        var pid: pid_t = on ? me : -1
        let status = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<pid_t>.size), &pid)
        return status == noErr && (hogOwner(id) == me) == on
    }

    // MARK: Hardware volume

    /// Elements carrying a volume control: the main element, else channels 1 and 2.
    private static func volumeElements(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        func has(_ e: AudioObjectPropertyElement) -> Bool {
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, e)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
        }
        if has(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(has)
    }

    static func hasHardwareVolume(_ id: AudioDeviceID) -> Bool { !volumeElements(id).isEmpty }

    static func hardwareVolume(_ id: AudioDeviceID) -> Float? {
        guard let e = volumeElements(id).first else { return nil }
        return get(id, address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, e), Float32(0))
    }

    static func setHardwareVolume(_ id: AudioDeviceID, _ v: Float) {
        for e in volumeElements(id) {
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, e)
            var value = Float32(max(0, min(1, v)))
            AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    // MARK: Change notifications

    /// Calls `block` on the main queue when devices are added/removed or the default output changes.
    static func observeDeviceChanges(_ block: @escaping () -> Void) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var a = address(sel)
            AudioObjectAddPropertyListenerBlock(system, &a, DispatchQueue.main) { _, _ in block() }
        }
    }
}
