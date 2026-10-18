import AppKit

/// Links looked up when they're clicked (an album's Wikipedia article, an artist's subreddit): what's found is
/// kept for the session, so the next click opens it at once. A click while the same link is still being looked up
/// does nothing (MusicBrainz answers about once a second, and a second tab isn't wanted); `busy` lets a button
/// show it's working.
@MainActor
enum LookedUpLinks {
    private static var found: [String: URL] = [:]
    private static var looking: Set<String> = []

    static func albumWikipedia(releaseGroup: String?, artist: String, title: String, busy: ((Bool) -> Void)? = nil) {
        let key = "wikipedia\u{1}" + (releaseGroup ?? Keys.artist(artist) + "\u{1}" + Keys.fold(title))
        open(key, otherwise: MetadataLookup.wikipediaSearch(artist: artist, title: title), busy: busy) {
            await MetadataLookup.shared.albumWikipedia(releaseGroup: releaseGroup, artist: artist, title: title)
        }
    }

    static func subreddit(artist: String, mbid: String?, busy: ((Bool) -> Void)? = nil) {
        let search = MetadataLookup.redditSearch(artist: artist)
        guard let mbid else { NSWorkspace.shared.open(search); return }
        open("reddit\u{1}" + mbid, otherwise: search, busy: busy) { await MetadataLookup.shared.subreddit(mbid: mbid) }
    }

    /// Not found (or no answer): `otherwise`, and the next click looks again.
    private static func open(_ key: String, otherwise: URL, busy: ((Bool) -> Void)?, find: @escaping @Sendable () async -> URL?) {
        if let url = found[key] { NSWorkspace.shared.open(url); return }
        guard looking.insert(key).inserted else { return }
        busy?(true)
        Task { @MainActor in
            let url = await find()
            if let url { found[key] = url }
            looking.remove(key)
            busy?(false)
            NSWorkspace.shared.open(url ?? otherwise)
        }
    }
}
