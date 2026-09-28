import Foundation

/// OPML, the file podcast apps use to move subscriptions: `<outline type="rss" text="…" xmlUrl="…"/>`, often
/// grouped in folders (nested outlines). Reading is forgiving: any outline with a feed address counts.
enum PodcastOPML {
    static func read(_ data: Data) -> [PodcastShow] { parse(data).shows }

    /// `complete` is false when the file is damaged and reading stopped early (the shows before it are kept).
    static func parse(_ data: Data) -> (shows: [PodcastShow], complete: Bool) {
        let r = Reader()
        let x = XMLParser(data: XMLRepair.repair(data))
        x.delegate = r
        let ok = x.parse()
        return (r.shows, ok)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var shows: [PodcastShow] = []
        private var seen = Set<String>()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            guard name.lowercased() == "outline" else { return }
            // Attribute names vary in case between apps (xmlUrl, xmlURL…).
            let attrs = Dictionary(a.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { x, _ in x })
            guard let feed = attrs["xmlurl"]?.trimmingCharacters(in: .whitespaces), !feed.isEmpty,
                  let u = URL(string: feed), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  seen.insert(feed).inserted else { return }
            let title = [attrs["title"], attrs["text"]].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            shows.append(PodcastShow(feedURL: feed, title: title ?? feed, author: "", artwork: attrs["imageurl"], genre: nil))
        }
    }

    /// OPML 2.0 with one outline per show.
    static func write(_ shows: [PodcastShow], date: Date = Date()) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let when = date.formatted(.dateTime.locale(Locale(identifier: "en_US_POSIX")).weekday(.abbreviated).day(.twoDigits)
            .month(.abbreviated).year().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>OmniAmp podcast subscriptions</title>
            <dateCreated>\(esc(when))</dateCreated>
          </head>
          <body>

        """
        for s in shows {
            out += "    <outline type=\"rss\" text=\"\(esc(s.title))\" title=\"\(esc(s.title))\" xmlUrl=\"\(esc(s.feedURL))\""
            if let a = s.artwork { out += " imageUrl=\"\(esc(a))\"" }
            out += "/>\n"
        }
        out += "  </body>\n</opml>\n"
        return Data(out.utf8)
    }
}
