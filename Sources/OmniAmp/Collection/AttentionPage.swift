import AppKit

/// Needs Attention: what could be better in the library, a card per kind of problem.
final class AttentionPage: NSScrollView {
    var onFix: ((LibraryAttention.Fix) -> Void)?
    private let stack = NSStackView()
    private var generation = 0
    /// One group's full list (its id), or nil for the overview.
    private(set) var group: String?
    /// What was built last: a refresh of the same view keeps its scroll position.
    private var shown: String??

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

    /// The overview (from the sidebar), or one group's full list.
    func reload(group: String? = nil) {
        self.group = group
        load()
    }

    private func load() {
        generation += 1
        let gen = generation, only = group
        let keepScroll = shown == .some(only) ? contentView.bounds.origin : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let a = (only == nil ? try? CollectionDB().attention() : try? CollectionDB().attention(limit: 5000, only: only)) ?? LibraryAttention()
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.build(a)
                self.shown = .some(only)
                if let keepScroll {
                    self.contentView.scroll(to: keepScroll)
                    self.reflectScrolledClipView(self.contentView)
                }
            }
        }
    }

    @objc private func back() {
        group = nil
        load()
    }

    private func build(_ a: LibraryAttention) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if group != nil { buildGroup(a.groups.first); return }
        var rows: [NSView] = [dashHeading("Needs attention", a.groups.isEmpty ? "Nothing to fix: the library is in good shape."
                                            : "\(a.total.formatted()) things that could be better · click one to fix it")]
        var cards: [NSView] = a.groups.map { g in
            let list = RowListChart()
            list.rows = self.rows(g)
            if g.total > g.entries.count {
                list.rows.append(.init(lead: "", main: "Show all \(g.total.formatted()) ›", detail: "", tip: "The whole list",
                                       action: { [weak self] in self?.group = g.id; self?.load() }))
            }
            return StatsPanel("\(g.title) (\(g.total.formatted()))", list, note: g.note)
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

    private func rows(_ g: LibraryAttention.Group) -> [RowListChart.Row] {
        g.entries.map { e in
            .init(lead: e.lead, main: e.title, detail: e.detail, tip: tip(e.fix), action: { [weak self] in self?.onFix?(e.fix) })
        }
    }

    /// One kind of problem, all of it.
    private func buildGroup(_ g: LibraryAttention.Group?) {
        let backButton = Pill("‹  Needs Attention", target: self, action: #selector(back))
        let title = Dash.label(g?.title ?? "Nothing left here", Dash.font(22, .semibold), Dash.text)
        let top = NSStackView(views: [backButton, title])
        top.spacing = 12
        var views: [NSView] = [top]
        if let g {
            let list = RowListChart()
            list.rows = self.rows(g)
            views.append(StatsPanel("\(g.title) (\(g.total.formatted()))", list, note: g.note))
        }
        for v in views {
            stack.addArrangedSubview(v)
            if !(v is NSStackView) { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            v.setContentHuggingPriority(.required, for: .vertical)
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
        case .folder(let f): "\(f)\nClick to show it in Finder"
        }
    }
}
