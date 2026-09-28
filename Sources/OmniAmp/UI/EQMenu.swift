import AppKit

/// The equalizer's On switch and presets as a menu: the same one in the menu bar, the options menus and
/// both looks' EQ.
@MainActor
final class EQMenu: NSObject, NSMenuDelegate {
    private weak var controller: PlayerController?
    private static var targetKey = 0

    private init(_ controller: PlayerController) { self.controller = controller }

    /// `withOnSwitch`: false where the EQ shows its own ON button.
    static func make(_ controller: PlayerController, withOnSwitch: Bool = true) -> NSMenu {
        let target = EQMenu(controller)
        let m = NSMenu(title: "Equalizer")
        if withOnSwitch {
            m.addItem(withTitle: "Equalizer On", action: #selector(toggle(_:)), keyEquivalent: "").target = target
            m.addItem(.separator())
        }
        for p in Equalizer.presets {
            let it = m.addItem(withTitle: p.name, action: #selector(pick(_:)), keyEquivalent: "")
            it.target = target
            it.representedObject = p.name
        }
        m.delegate = target
        // Menu items hold their target weakly: the menu keeps it.
        objc_setAssociatedObject(m, &targetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let on = controller?.eqSettings.enabled == true
        for it in menu.items where it.action == #selector(toggle(_:)) { it.state = on ? .on : .off }
    }

    @objc private func toggle(_ sender: Any?) {
        guard let c = controller else { return }
        var s = c.eqSettings
        s.enabled.toggle()
        c.setEQ(s)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        if let p = Equalizer.presets.first(where: { $0.name == sender.representedObject as? String }) { controller?.applyPreset(p) }
    }
}
