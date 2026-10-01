import Foundation
import os

/// Reads a FLAC file on a network share through once, in the background, when it starts playing, so a seek finds it
/// in macOS's file cache.
///
/// Core Audio's FLAC decoder (behind AVAudioFile) finds a seek point by reading the file up to it, and it ignores
/// FLAC seek tables. Over NFS that's the network's speed: the middle of a 24/96 track (40 MB in) took over a second
/// at ~40 MB/s; from the cache, about a tenth of that. Playback only needs a few Mbit/s, so reading ahead costs a few
/// seconds of the network once per track. Only raw bytes into a scratch buffer: the app keeps nothing, the cache is
/// the system's (freed when it needs the room).
enum FileWarmer {
    /// The track being read through; a newer one (or a stop) makes an older read stop at its next chunk.
    private static let ticket = OSAllocatedUnfairLock(initialState: 0)
    /// Single-file images (a whole concert with a CUE sheet) bigger than this aren't read ahead.
    static let largest: Int64 = 600 << 20

    static func warm(_ url: URL) {
        let mine = ticket.withLock { t -> Int in t += 1; return t }
        guard url.isFileURL, url.pathExtension.lowercased() == "flac" else { return }
        DispatchQueue.global(qos: .utility).async {
            // Local disks are fast enough (a scan to the middle is ~80 ms); only network shares are read ahead.
            guard TagQueue.isNetworkVolume(url.path) else { return }
            let fd = url.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY) } ?? -1 }
            guard fd >= 0 else { return }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_size <= largest else { return }
            let chunk = 4 << 20
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
            defer { buffer.deallocate() }
            while ticket.withLock({ $0 }) == mine {
                let n = read(fd, buffer, chunk)
                if n <= 0 { break }
            }
        }
    }

    /// Playback stopped: a read still going stops too.
    static func cancel() { ticket.withLock { $0 += 1 } }
}
