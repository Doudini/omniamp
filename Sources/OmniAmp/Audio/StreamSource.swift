import AudioToolbox
import AVFoundation

/// Pulls an Icecast/SHOUTcast stream (MP3 or AAC), strips ICY metadata, decodes to PCM and hands out
/// buffers. Works on its own serial queue; callbacks arrive on that queue.
///
/// Thread rule (why it's `@unchecked Sendable`): the owner sets the callbacks, then calls `start()` and later
/// `stop()`; everything else (headers, metadata, decoding) happens on `queue`, where URLSession delivers.
final class StreamSource: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Info: Sendable {
        var name: String?
        var bitrate: Int?          // kbps (icy-br)
        var codec: String?         // "MP3" / "AAC"
        var sampleRate: Double = 0
        var channels: Int = 0
    }

    /// Decoded audio, ready to schedule.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// "StreamTitle" changed (usually "Artist - Title").
    var onTitle: (@Sendable (String) -> Void)?
    /// Headers known / format known.
    var onInfo: (@Sendable (Info) -> Void)?
    /// Connection ended (error or server closed).
    var onEnd: (@Sendable (Error?) -> Void)?
    /// The stream is a format this decoder doesn't handle (HLS playlist, Ogg/Opus/FLAC…, or audio it couldn't
    /// make sense of): content type given.
    var onUnsupported: (@Sendable (String) -> Void)?

    /// Content types that go to the system player instead.
    /// `length`: what the server says the body is (-1: open-ended, a live stream).
    static func isSystemPlayerType(_ type: String, length: Int64 = -1) -> Bool {
        let t = type.lowercased()
        if t.contains("mpegurl") || t.contains("ogg") || t.contains("opus") || t.contains("vorbis") { return true }
        // A live FLAC stream is read here (the system player waits forever on one). A FLAC of a given length is a
        // file (Radio Paradise's "stations" are an hour-long file each): the system player plays it once, to its
        // end, where a stream here would reconnect and start it over.
        return t.contains("flac") && length > 0
    }

    /// URLs that are clearly HLS / Ogg / Opus, before connecting.
    static func isSystemPlayerURL(_ url: URL) -> Bool {
        let p = url.path.lowercased()
        return p.hasSuffix(".m3u8") || p.hasSuffix(".opus") || p.hasSuffix(".ogg") || p.hasSuffix(".oga")
    }

    let url: URL
    private(set) var info = Info()
    private let queue = DispatchQueue(label: "omniamp.stream")
    private var session: URLSession?
    private var task: URLSessionDataTask?

    // ICY demux state.
    private var metaInterval = 0
    private var audioBytesUntilMeta = 0
    private var metaRemaining = -1          // -1: not in a metadata block
    private var metaBuffer = Data()

    // Decoding.
    private var fileStream: AudioFileStreamID?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var pendingPackets: [(Data, AudioStreamPacketDescription?)] = []
    private var contentType = ""
    /// Bytes read while no format was found yet, and whether this connection was given up on.
    private var undecodedBytes = 0
    private var gaveUp = false
    /// No MP3 or AAC frame in this much (a few seconds even at a high bitrate): it's something else.
    static let formatSearchLimit = 128 * 1024
    private var packetQueue: [(Data, AudioStreamPacketDescription?)] = []

    init(url: URL) {
        self.url = url
    }

    func start() {
        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = .infinity
        let opQueue = OperationQueue()
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: opQueue)
        task = session?.dataTask(with: req)
        task?.resume()
    }

    func stop() {
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        queue.async {
            if let fs = self.fileStream { AudioFileStreamClose(fs); self.fileStream = nil }
        }
    }

    // MARK: URLSession

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        func header(_ k: String) -> String? { http?.value(forHTTPHeaderField: k) }
        metaInterval = Int(header("icy-metaint") ?? "") ?? 0
        audioBytesUntilMeta = metaInterval
        info.name = header("icy-name")
        info.bitrate = Int((header("icy-br") ?? "").split(separator: ",").first ?? "")
        let type = (header("Content-Type") ?? response.mimeType ?? "").lowercased()
        if Self.isSystemPlayerType(type, length: response.expectedContentLength) {
            completionHandler(.cancel)
            onUnsupported?(type)
            return
        }
        if let code = http?.statusCode, !(200..<300).contains(code) {
            completionHandler(.cancel)
            onEnd?(ScrobbleError.http(code, "Station unavailable"))
            return
        }
        openParser(type: type)
        onInfo?(info)
        completionHandler(.allow)
    }

    private func openParser(type: String) {
        contentType = type
        let hint: AudioFileTypeID
        if type.contains("aac") || type.contains("mp4") { hint = kAudioFileAAC_ADTSType; info.codec = "AAC" }
        else if type.contains("flac") { hint = kAudioFileFLACType; info.codec = "FLAC" }
        else { hint = kAudioFileMP3Type; info.codec = "MP3" }
        let me = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(me, { ctx, stream, prop, _ in
            Unmanaged<StreamSource>.fromOpaque(ctx).takeUnretainedValue().property(stream, prop)
        }, { ctx, bytes, packets, data, descs in
            Unmanaged<StreamSource>.fromOpaque(ctx).takeUnretainedValue().packets(bytes, packets, data, descs)
        }, hint, &fileStream)
    }

    /// Test hook: start decoding as if the server had answered with this content type (no network).
    func openForTesting(type: String) { openParser(type: type) }

    /// This decoder can't play it: hand it on (the system player knows more formats) instead of "buffering" forever
    /// while the download piles up undecoded.
    private func giveUp(_ why: String) {
        guard !gaveUp else { return }
        gaveUp = true
        packetQueue.removeAll()
        NSLog("OmniAmp: stream not decodable here (%@, %@)", why, contentType.isEmpty ? "no content type" : contentType)
        onUnsupported?(contentType.isEmpty ? "unknown" : contentType)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        demux(data)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if (error as? URLError)?.code == .cancelled { return }
        onEnd?(error)
    }

    // MARK: ICY metadata

    /// Test hook: feed raw stream bytes with a given icy-metaint (no network).
    func feedForTesting(_ data: Data, metaInterval: Int) {
        if self.metaInterval != metaInterval { self.metaInterval = metaInterval; audioBytesUntilMeta = metaInterval }
        demux(data)
    }

    /// Split interleaved audio and "StreamTitle='…';" blocks (every icy-metaint bytes).
    private func demux(_ data: Data) {
        guard metaInterval > 0 else { parse(data); return }
        var i = data.startIndex
        while i < data.endIndex {
            if metaRemaining < 0 {
                let n = min(audioBytesUntilMeta, data.endIndex - i)
                if n > 0 { parse(data[i..<(i + n)]); i += n; audioBytesUntilMeta -= n }
                if audioBytesUntilMeta == 0, i < data.endIndex {
                    metaRemaining = Int(data[i]) * 16
                    i += 1
                    metaBuffer.removeAll(keepingCapacity: true)
                    if metaRemaining == 0 { metaRemaining = -1; audioBytesUntilMeta = metaInterval }
                }
            } else {
                let n = min(metaRemaining, data.endIndex - i)
                metaBuffer.append(data[i..<(i + n)])
                i += n
                metaRemaining -= n
                if metaRemaining == 0 {
                    handleMetadata(metaBuffer)
                    metaRemaining = -1
                    audioBytesUntilMeta = metaInterval
                }
            }
        }
    }

    private func handleMetadata(_ d: Data) {
        let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        if let t = Self.streamTitle(s) { onTitle?(t) }
    }

    /// StreamTitle='Artist - Title';StreamUrl='';
    static func streamTitle(_ meta: String) -> String? {
        guard let r = meta.range(of: "StreamTitle='") else { return nil }
        let rest = meta[r.upperBound...]
        let end = rest.range(of: "';")?.lowerBound ?? rest.lastIndex(of: "'") ?? rest.endIndex
        let t = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    // MARK: Parsing (AudioFileStream) and decoding (AVAudioConverter)

    private func parse(_ d: Data) {
        guard let fs = fileStream, !d.isEmpty, !gaveUp else { return }
        d.withUnsafeBytes { p in
            _ = AudioFileStreamParseBytes(fs, UInt32(d.count), p.baseAddress, [])
        }
        if converter == nil, !gaveUp {
            undecodedBytes += d.count
            if undecodedBytes > Self.formatSearchLimit { giveUp("no MP3 or AAC audio found") }
        }
    }

    private func property(_ stream: AudioFileStreamID, _ prop: AudioFileStreamPropertyID) {
        guard prop == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &asbd)
        if let best = Self.bestFormat(stream) { asbd = best }
        guard let inFmt = AVAudioFormat(streamDescription: &asbd),
              let outFmt = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: max(1, asbd.mChannelsPerFrame)),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { giveUp("no decoder for its format"); return }
        // Magic cookie (AAC needs it).
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie)
            conv.magicCookie = Data(cookie)
        }
        inputFormat = inFmt
        outputFormat = outFmt
        converter = conv
        info.sampleRate = asbd.mSampleRate
        info.channels = Int(asbd.mChannelsPerFrame)
        onInfo?(info)
    }

    /// The richest layer of the stream the decoder can play. An AAC+ (HE-AAC) station's data format is its 22 kHz
    /// core; the format list also names the full one (the core plus the layer that rebuilds the treble, and for v2
    /// the stereo), best first. Decoding only the core played those stations at half bandwidth, muffled.
    private static func bestFormat(_ stream: AudioFileStreamID) -> AudioStreamBasicDescription? {
        var listSize: UInt32 = 0
        guard AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_FormatList, &listSize, nil) == noErr, listSize > 0 else { return nil }
        let count = Int(listSize) / MemoryLayout<AudioFormatListItem>.size
        var list = [AudioFormatListItem](repeating: AudioFormatListItem(), count: count)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FormatList, &listSize, &list) == noErr else { return nil }
        var index: UInt32 = 0
        var indexSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_FirstPlayableFormatFromList, listSize, &list, &indexSize, &index) == noErr,
              Int(index) < count else { return nil }
        return list[Int(index)].mASBD
    }

    private func packets(_ bytes: UInt32, _ count: UInt32, _ data: UnsafeRawPointer,
                         _ descs: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard count > 0 else { return }
        for i in 0..<Int(count) {
            if let d = descs?[i] {
                let packet = Data(bytes: data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize))
                var desc = d
                desc.mStartOffset = 0
                packetQueue.append((packet, desc))
            } else {
                packetQueue.append((Data(bytes: data, count: Int(bytes)), nil))
                break
            }
        }
        decode()
    }

    /// Decode everything queued into PCM buffers of ~4096 frames.
    private func decode() {
        guard let conv = converter, let inFmt = inputFormat, let outFmt = outputFormat else { return }
        while packetQueue.count >= 8 {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 4096) else { return }
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, outStatus in
                guard !self.packetQueue.isEmpty else { outStatus.pointee = .noDataNow; return nil }
                let (bytes, desc) = self.packetQueue.removeFirst()
                let buf = AVAudioCompressedBuffer(format: inFmt, packetCapacity: 1, maximumPacketSize: max(bytes.count, 1))
                bytes.withUnsafeBytes { p in if let base = p.baseAddress { buf.data.copyMemory(from: base, byteCount: bytes.count) } }
                buf.byteLength = UInt32(bytes.count)
                buf.packetCount = 1
                if var d = desc {
                    d.mDataByteSize = UInt32(bytes.count)
                    buf.packetDescriptions?.pointee = d
                }
                outStatus.pointee = .haveData
                return buf
            }
            if out.frameLength > 0 { onBuffer?(out) }
            if status == .error || (status == .inputRanDry && out.frameLength == 0) { break }
        }
    }
}
