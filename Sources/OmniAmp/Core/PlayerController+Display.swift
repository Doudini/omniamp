import Foundation

/// Text the looks show for tracks and the playlist: titles, format lines, status.
extension PlayerController {
    func title(for index: Int) -> String {
        let t = store.tracks[index]
        if t.isStream {
            // "3. Groove Salad — Artist - Title", plus BUFFERING while it fills up.
            var s = "\(index + 1). \(t.title ?? player.streamInfo?.name ?? t.path)"
            if index == currentIndex, player.isStreaming {
                if player.isBuffering { s += " · BUFFERING…" } else if let st = player.streamTitle { s += " — \(st)" }
            } else if index == currentIndex, let err = player.streamError {
                s += " · couldn't connect: \(err)"
            }
            return s
        }
        let d = t.duration.map { " (\(TimeFormat.mmss($0)))" } ?? ""
        if t.isEpisode, index == currentIndex {
            if player.isPlayingEpisode, player.isBuffering { return "\(index + 1). \(t.displayTitle) · BUFFERING…" }
            if let err = player.streamError { return "\(index + 1). \(t.displayTitle) · couldn't load: \(err)" }
        }
        return "\(index + 1). \(t.displayTitle)\(d)"
    }

    /// Bitrate in kbps for display (FLAC: computed from size/duration).
    var currentKbps: Int? {
        guard let t = currentTrack else { return nil }
        if t.isStream { return player.streamInfo?.bitrate }
        if t.isEpisode { return t.bitrate }
        if let b = t.bitrate { return b }
        if let k = Sane.kbps(bytes: t.size, seconds: t.duration) { return k }
        return nil
    }

    var currentKHz: Int? {
        let sr = currentTrack?.sampleRate ?? Int(player.sampleRate)
        return sr > 0 ? Int((Double(sr) / 1000).rounded()) : nil
    }

    /// Human readable format, e.g. "FLAC 24-bit / 96 kHz" or "MP3 320 kbps · 44.1 kHz".
    var formatDescription: String { currentIndex.map { formatDescription(for: $0) } ?? "" }

    /// Format line for any track; the playing one also gets live info (actual rate, channels).
    func formatDescription(for index: Int) -> String {
        let l = formatLines(for: index)
        return [l.0, l.1].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The format split in two, for narrow layouts: ("FLAC 16-bit / 44.1 kHz", "801 kbps · stereo").
    func formatLines(for index: Int) -> (String, String) {
        guard index < store.tracks.count else { return ("", "") }
        let t = store.tracks[index]
        if t.isStream {
            guard index == currentIndex, let i = player.streamInfo else { return ("Internet radio", "") }
            let khz = i.sampleRate > 0 ? String(format: i.sampleRate.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0f kHz" : "%.1f kHz", i.sampleRate / 1000) : ""
            let ch = i.channels == 1 ? "mono" : (i.channels == 2 ? "stereo" : "")
            return (["RADIO", i.codec, i.bitrate.map { "\($0) kbps" }].compactMap { $0 }.joined(separator: " "),
                    [khz, ch].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        if t.isEpisode {
            // "PODCAST MP3" · "12 Mar 2026"
            let ext = (t.url.path as NSString).pathExtension.uppercased()
            let codec = ["MP3", "M4A", "AAC", "MP4", "OGG", "OPUS", "WAV"].contains(ext) ? (ext == "M4A" || ext == "MP4" ? "AAC" : ext) : ""
            let date = t.published.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? ""
            let sp = speed(for: t)
            let speedTag = sp == 1 ? "" : String(format: "%g×", sp)
            return ([t.isWebFile ? "WEB" : "PODCAST", codec, speedTag].filter { !$0.isEmpty }.joined(separator: " "), date)
        }
        let playing = index == currentIndex && player.state != .stopped
        let ext = (t.path as NSString).pathExtension.lowercased()
        let lossless = t.bitDepth != nil
        let codec: String
        switch ext {
        case "flac": codec = "FLAC"
        case "mp3": codec = "MP3"
        case "wav", "wave": codec = "WAV"
        case "aif", "aiff", "aifc": codec = "AIFF"
        case "m4a", "m4b", "mp4", "alac": codec = lossless ? "ALAC" : "AAC"
        case "aac": codec = "AAC"
        default: codec = ext.uppercased()
        }
        let sr = t.sampleRate ?? (playing ? Int(player.sampleRate) : 0)
        let khz = sr > 0 ? (sr % 1000 == 0 ? "\(sr / 1000) kHz" : String(format: "%.1f kHz", Double(sr) / 1000)) : ""
        let channels = playing ? player.channelCount : 0
        let ch = channels == 1 ? "mono" : (channels == 2 ? "stereo" : (channels > 2 ? "\(channels) ch" : ""))
        let kbps = t.bitrate ?? Sane.kbps(bytes: t.size, seconds: t.duration)
        func join(_ p: [String]) -> String {
            p.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if lossless, let bits = t.bitDepth {
            return (join(["\(codec) \(bits)-bit / \(khz)"]), join([kbps.map { "\($0) kbps" } ?? "", ch]))
        }
        return (join(["\(codec) \(kbps.map { "\($0) kbps" } ?? "")"]), join([khz, ch]))
    }

    /// Tracks of the same album in the playlist (same album tag, and same folder or artist).
    func albumSummary(for index: Int) -> (count: Int, duration: Double)? {
        guard index < store.tracks.count, let album = store.tracks[index].album, !album.isEmpty else { return nil }
        let t = store.tracks[index]
        let dir = (t.path as NSString).deletingLastPathComponent
        var n = 0, d = 0.0
        for o in store.tracks where o.album == album && ((o.path as NSString).deletingLastPathComponent == dir || o.artist == t.artist) {
            n += 1
            d += o.duration ?? 0
        }
        return (n, d)
    }

    var statusText: String {
        if let p = playbackProblem { return p }
        let total = store.tracks.count
        // While a folder is being added: how far along it is.
        if store.scansInProgress > 0 {
            return "Adding… \(store.scannedSoFar.formatted()) files"
        }
        var s = visible == nil ? "\(total) tracks" : "\(rowCount)/\(total) tracks"
        let dur = store.totalDuration
        if dur > 0 { s += "  \(TimeFormat.mmss(dur))" }
        if store.isLoadingTags { s += "  …" }
        if stopAfterCurrent { s = "⏹ after this · " + s }
        if let at = sleepAt { s = "☾ \(max(1, Int(ceil(at.timeIntervalSinceNow / 60))))m · " + s }
        return s
    }
}
