import AppKit

/// Needs Attention: what could be better in the library, a card per kind of problem.
final class AttentionPage: NSScrollView {
    var onFix: ((LibraryAttention.Fix) -> Void)?
    private let stack = NSStackView()
    private var generation = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        hasVerticalScroller = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        generation += 1
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let a = (try? CollectionDB().attention()) ?? LibraryAttention()
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.build(a)
            }
        }
    }

    private func build(_ a: LibraryAttention) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var rows: [NSView] = [dashHeading("Needs attention", a.groups.isEmpty ? "Nothing to fix: the library is in good shape."
                                            : "\(a.total.formatted()) things that could be better · click one to fix it")]
        var cards: [NSView] = a.groups.map { g in
            let list = RowListChart()
            list.rows = g.entries.map { e in
                .init(lead: e.lead, main: e.title, detail: e.detail, tip: tip(e.fix), action: { [weak self] in self?.onFix?(e.fix) })
            }
            let more = g.total > g.entries.count ? " · \(g.entries.count) of \(g.total.formatted()) shown" : ""
            return StatsPanel("\(g.title) (\(g.total.formatted()))", list, note: g.note + more)
        }
        // Two cards a row (equal height), an odd one out full width.
        while !cards.isEmpty {
            let pair = Array(cards.prefix(2))
            cards.removeFirst(pair.count)
            rows.append(dashGrid(pair.map { ($0, pair.count == 1 ? 2 : 1) }, columns: 2))
        }
        for r in rows {
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            r.setContentHuggingPriority(.required, for: .vertical)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)
        Dash.relaxWidth(stack)
        layoutSubtreeIfNeeded()
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    private func tip(_ f: LibraryAttention.Fix) -> String {
        switch f {
        case .findInfo: "Click to open it and look it up (Find Missing Info)"
        case .open: "Click to open it in the library"
        case .artist: "Click for the artist"
        }
    }
}
