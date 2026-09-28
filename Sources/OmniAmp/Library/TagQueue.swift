import Foundation

/// Stage 2 for the playlist and the library alike: tags read in parallel on shared queues, so however many
/// loads overlap, the total width stays bounded and no thread blocks waiting.
enum TagQueue {
    /// Call from a background thread (the volume check can stall on a slow share). `chunk` gets each chunk's
    /// results on a reader thread; `done` runs on `doneQueue` once all are read.
    static func read<ID: Sendable>(_ work: [(id: ID, path: String, size: Int64)], chunk deliver: @escaping @Sendable ([(id: ID, info: TagInfo)]) -> Void,
                                   doneQueue: DispatchQueue = .main, done: @escaping @Sendable () -> Void) {
        guard !work.isEmpty else { doneQueue.async(execute: done); return }
        // Network shares: reads mostly wait on the server, so keep many in flight; local disks: one per core.
        let remote = isNetworkVolume(work[0].path)
        let size = remote ? 8 : 64
        let queue = remote ? remoteQueue : localQueue
        let group = DispatchGroup()
        for start in stride(from: 0, to: work.count, by: size) {
            let slice = work[start..<min(start + size, work.count)]
            group.enter()
            queue.addOperation {
                var local: [(id: ID, info: TagInfo)] = []
                local.reserveCapacity(slice.count)
                let buffer = TagReadBuffer()
                for w in slice { local.append((w.id, TagReader.read(path: w.path, fileSize: w.size, buffer: buffer))) }
                deliver(local)
                group.leave()
            }
        }
        group.notify(queue: doneQueue, execute: done)
    }

    private static func queue(_ name: String, width: Int) -> OperationQueue {
        let q = OperationQueue()
        q.name = name
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = width
        return q
    }
    private static let localQueue = queue("omniamp.tags.local", width: ProcessInfo.processInfo.activeProcessorCount)
    private static let remoteQueue = queue("omniamp.tags.remote", width: 24)

    static func isNetworkVolume(_ path: String) -> Bool {
        (try? URL(exactPath: path).resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
    }
}
