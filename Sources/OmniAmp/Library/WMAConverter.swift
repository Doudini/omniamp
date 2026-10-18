import Foundation

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

    private struct Failure: Error { let message: String }

    private static func convertOne(_ path: String, ffmpeg: String) -> Swift.Result<(String, Bool), Failure> {
        let base = (path as NSString).deletingPathExtension
        let out = base + ".flac"
        guard ExactPath.kind(out) == nil else { return .failure(Failure(message: "a .flac of that name is already there")) }
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/.omniamp-\(UUID().uuidString.prefix(8)).flac"
        let p = Process()
        p.executableURL = URL(exactPath: ffmpeg)
        // Audio and tags; a picture stream, if any, as the FLAC's cover.
        p.arguments = ["-nostdin", "-v", "error", "-i", path, "-map", "0:a:0", "-map", "0:v?", "-c:a", "flac", "-c:v", "copy",
                       "-disposition:v", "attached_pic", "-map_metadata", "0", "-f", "flac", tmp]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(Failure(message: "couldn't start ffmpeg")) }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, ExactPath.kind(tmp) != nil else {
            unlink(tmp)
            let why = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "ffmpeg failed"
            return .failure(Failure(message: why))
        }
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
}
