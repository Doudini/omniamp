import Foundation
import os

/// Turns WMA files (which macOS can't decode) into FLAC with the user's own ffmpeg, if they have one: OmniAmp
/// ships no decoder for it. The FLAC goes next to the WMA with its tags (and the WMA's date, which is when it came
/// into the collection); the WMA then goes to the Trash. Where the folder has no Trash (some network shares), the
/// WMA stays and the line says so: nothing is deleted outright.
enum WMAConverter {
    static let extensions: Set<String> = ["wma"]

    static func isWMA(_ path: String) -> Bool { extensions.contains((path as NSString).pathExtension.lowercased()) }

    /// Homebrew (Apple silicon, Intel), MacPorts, then the PATH a Terminal would have.
    nonisolated static var ffmpeg: String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { $0 + "/ffmpeg" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// One file's longest run: a read stalled on a share would otherwise hold every later conversion up for good.
    static let timeLimit: TimeInterval = 600

    /// The ffmpeg running now and the file it writes, so quitting can stop it and leave no partial file behind.
    private static let running = OSAllocatedUnfairLock<(pid: Int32, tmp: String)?>(initialState: nil)

    /// At quit: the running conversion stops, its partial file goes (the WMA is still there).
    static func stop() {
        guard let r = running.withLock({ $0 }) else { return }
        kill(r.pid, SIGTERM)
        unlink(r.tmp)
    }

    struct Result: Sendable {
        var converted: [String] = []   // the new FLACs
        var failed: [String] = []      // "name: why"
        var keptOriginals = 0          // converted, but the WMA couldn't go to the Trash
        var line: String {
            var parts: [String] = []
            if !converted.isEmpty { parts.append("converted \(converted.count) file\(converted.count == 1 ? "" : "s") to FLAC") }
            if keptOriginals > 0 { parts.append("\(keptOriginals) WMA kept (no Trash there)") }
            if !failed.isEmpty { parts.append("\(failed.count) failed: \(failed[0])") }
            let s = parts.joined(separator: " · ")
            return s.isEmpty ? "Nothing to convert." : s.prefix(1).uppercased() + s.dropFirst() + "."
        }
    }

    /// Off the main thread, one file at a time (a share is slow enough with one). `progress` gets the count done.
    nonisolated static func convert(_ paths: [String], ffmpeg: String, progress: @Sendable (Int) -> Void = { _ in }) -> Result {
        for dir in Set(paths.map { ($0 as NSString).deletingLastPathComponent }) { TagWriter.removeStaleTemporaries(in: dir) }
        var r = Result()
        for (i, p) in paths.enumerated() {
            progress(i)
            switch convertOne(p, ffmpeg: ffmpeg) {
            case .success(let (flac, trashed)):
                r.converted.append(flac)
                if !trashed { r.keptOriginals += 1 }
            case .failure(let e):
                r.failed.append("\((p as NSString).lastPathComponent): \(e.message)")
            }
        }
        return r
    }

    struct Failure: Error { let message: String }

    private static func convertOne(_ path: String, ffmpeg: String) -> Swift.Result<(String, Bool), Failure> {
        let out = (path as NSString).deletingPathExtension + ".flac"
        guard ExactPath.kind(out) == nil else { return .failure(Failure(message: "a .flac of that name is already there")) }
        // ".tmp", like TagWriter's, so a crash's leftover is cleaned up the next time.
        let tmp = (path as NSString).deletingLastPathComponent + "/.omniamp-\(UUID().uuidString.prefix(8)).tmp"
        // Lossy WMA decodes to floating point, which ffmpeg would write as 24-bit FLAC: half as big again for
        // nothing. WMA Lossless keeps its own bit depth.
        let audio = ["-map", "0:a:0", "-c:a", "flac"] + (isLosslessWMA(path) ? [] : ["-sample_fmt", "s16"])
        // With the cover (a picture stream) if there is one; without it if that's what fails.
        var result = run(ffmpeg, ["-nostdin", "-v", "error", "-i", path] + audio
                         + ["-map", "0:v?", "-c:v", "copy", "-disposition:v", "attached_pic", "-map_metadata", "0", "-f", "flac", tmp], tmp: tmp)
        if case .failure(let e) = result, e.message != "timed out" {
            result = run(ffmpeg, ["-nostdin", "-v", "error", "-i", path] + audio + ["-map_metadata", "0", "-f", "flac", tmp], tmp: tmp)
        }
        if case .failure(let e) = result { return .failure(e) }
        // The WMA's date: when the music came into the collection (Recently Added).
        var st = stat()
        if stat(path, &st) == 0 {
            var ts = [st.st_atimespec, st.st_mtimespec]
            _ = utimensat(AT_FDCWD, tmp, &ts, 0)
        }
        guard rename(tmp, out) == 0 else {
            unlink(tmp)
            return .failure(Failure(message: "couldn't write the .flac"))
        }
        let trashed = (try? FileManager.default.trashItem(at: URL(exactPath: path), resultingItemURL: nil)) != nil
        return .success((out, trashed))
    }

    /// ffmpeg writing `tmp`, stopped after `timeLimit`. On failure `tmp` is gone and the message is ffmpeg's last line.
    private static func run(_ ffmpeg: String, _ args: [String], tmp: String) -> Swift.Result<Void, Failure> {
        let p = Process()
        p.executableURL = URL(exactPath: ffmpeg)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return .failure(Failure(message: "couldn't start ffmpeg")) }
        running.withLock { $0 = (p.processIdentifier, tmp) }
        defer { running.withLock { $0 = nil } }
        // Read as it comes, so a chatty ffmpeg never blocks on a full pipe.
        let message = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let d = err.fileHandleForReading.readDataToEndOfFile()
            message.withLock { $0 = d }
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeLimit) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            unlink(tmp)
            return .failure(Failure(message: "timed out"))
        }
        guard p.terminationStatus == 0, ExactPath.kind(tmp) != nil else {
            unlink(tmp)
            _ = drained.wait(timeout: .now() + 2)
            let text = String(decoding: message.withLock { $0 }, as: UTF8.self)
            return .failure(Failure(message: text.split(separator: "\n").last.map(String.init) ?? "ffmpeg failed"))
        }
        return .success(())
    }

    /// WMA Lossless: format tag 0x0163 in the ASF header's audio stream properties. Anything unreadable counts as
    /// lossy (16-bit output, which is what lossy WMA holds anyway).
    static func isLosslessWMA(_ path: String) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: URL(exactPath: path)) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 30), head.count == 30 else { return false }
        let b = [UInt8](head)
        let size = (16..<24).reversed().reduce(0) { $0 << 8 | Int(b[$1]) }
        guard size > 30, size <= 16 << 20, let rest = try? h.read(upToCount: size - 30) else { return false }
        let header = b + [UInt8](rest)
        let streamProperties: [UInt8] = [0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
        let audioStream: [UInt8] = [0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B]
        var i = 30
        while i + 80 <= header.count {
            if header[i] == 0x91, Array(header[i..<(i + 16)]) == streamProperties, Array(header[(i + 24)..<(i + 40)]) == audioStream {
                return Int(header[i + 78]) | Int(header[i + 79]) << 8 == 0x0163
            }
            i += 1
        }
        return false
    }
}
