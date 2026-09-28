import AppKit

/// Show notes and comments laid out for reading, in the app's own font: space between paragraphs,
/// hyphenated wrapping (long words in a narrow monospaced column left big gaps), links clickable.
enum NotesText {
    /// `links`: [text, url] pairs from the feed, put back on their text; bare web addresses are found too.
    static func attributed(_ text: String, links: [[String]]? = nil, font: NSFont, color: NSColor) -> NSAttributedString {
        let body = paragraphs(text)
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacing = round(font.pointSize * 0.7)
        ps.hyphenationFactor = 0.9
        ps.lineBreakMode = .byWordWrapping
        let out = NSMutableAttributedString(string: body, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])
        let ns = body as NSString
        var linked: [NSRange] = []
        func isFree(_ r: NSRange) -> Bool { !linked.contains { NSIntersectionRange($0, r).length > 0 } }
        for pair in links ?? [] where pair.count == 2 {
            guard let url = URL(string: pair[1]) else { continue }
            // The first occurrence of the link's text that isn't linked yet.
            var from = 0
            while from < ns.length {
                let r = ns.range(of: pair[0], range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                if isFree(r) { out.addAttribute(.link, value: url, range: r); linked.append(r); break }
                from = r.location + r.length
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: body, range: NSRange(location: 0, length: ns.length)) where isFree(m.range) {
                if let url = m.url { out.addAttribute(.link, value: url, range: m.range); linked.append(m.range) }
            }
        }
        // A link must never be hyphenated ("megaphone.fm/adchoic-es"): no hyphenation in paragraphs with one.
        let plain = ps.mutableCopy() as! NSMutableParagraphStyle
        plain.hyphenationFactor = 0
        for r in linked { out.addAttribute(.paragraphStyle, value: plain, range: ns.paragraphRange(for: r)) }
        return out
    }

    /// Blank lines separate paragraphs (spaced apart); single line breaks stay inside one (U+2028, no space).
    /// Notes saved before paragraphs were kept have no blank lines at all: there every line is a paragraph.
    static func paragraphs(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains("\n\n") else { return t }
        return t.components(separatedBy: "\n\n").map { $0.replacingOccurrences(of: "\n", with: "\u{2028}") }.joined(separator: "\n")
    }
}

/// Read-only text that takes the height its content needs (in a stack view), with clickable links in the
/// text's own color. For the INFO drawer's notes.
final class NotesTextView: NSTextView {
    private var laidOutWidth: CGFloat = 0

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = true
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = false
        isHorizontallyResizable = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
    }

    func show(_ text: NSAttributedString) {
        // Links look like the rest of the text, just underlined.
        let color = text.length > 0 ? text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        linkTextAttributes = [.foregroundColor: color ?? NSColor.textColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
        textStorage?.setAttributedString(text)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        lm.ensureLayout(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(lm.usedRect(for: tc).height))
    }

    override func layout() {
        super.layout()
        // Another width wraps the text differently: ask for the new height.
        if abs(bounds.width - laidOutWidth) > 0.5 { laidOutWidth = bounds.width; invalidateIntrinsicContentSize() }
    }
}
