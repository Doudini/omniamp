import Foundation

/// Downloads with a ceiling on size and time. Feeds and logos come from addresses anyone can edit (radio-browser,
/// OPML files, podcast directories): one that points at a live stream or a huge file must not fill the memory or
/// the disk, and one that trickles must not hold a download slot for days (URLSession's own limit is 7 days).
enum BoundedFetch {
    struct TooLarge: LocalizedError {
        var errorDescription: String? { "the download is larger than expected" }
    }

    /// The body, at most `limit` bytes, within `deadline` seconds.
    static func data(for req: URLRequest, limit: Int, deadline: TimeInterval = 120) async throws -> (Data, URLResponse) {
        try await within(deadline) {
            var out = Data()
            let response = try await stream(req, limit: limit) { out.append(contentsOf: $0) }
            return (out, response)
        }
    }

    /// The body into a new temporary file (the caller moves or deletes it), at most `limit` bytes, within `deadline`.
    static func download(for req: URLRequest, limit: Int, deadline: TimeInterval = 120) async throws -> (URL, URLResponse) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-\(UUID().uuidString).download")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil), let h = try? FileHandle(forWritingTo: tmp) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let response = try await within(deadline) { try await stream(req, limit: limit) { try h.write(contentsOf: $0) } }
            try h.close()
            return (tmp, response)
        } catch {
            try? h.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Hands the body over in 64 KB pieces; stops (and cancels the request) past `limit`.
    private static func stream(_ req: URLRequest, limit: Int, _ sink: ([UInt8]) throws -> Void) async throws -> URLResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard response.expectedContentLength <= Int64(limit) else { bytes.task.cancel(); throw TooLarge() }
        var chunk: [UInt8] = [], total = 0
        chunk.reserveCapacity(1 << 16)
        do {
            for try await b in bytes {
                chunk.append(b)
                if chunk.count == 1 << 16 {
                    total += chunk.count
                    guard total <= limit else { throw TooLarge() }
                    try sink(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            bytes.task.cancel()
            throw error
        }
        guard total + chunk.count <= limit else { throw TooLarge() }
        try sink(chunk)
        return response
    }

    private static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
