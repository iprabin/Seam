import AppKit
import Carbon.HIToolbox

struct Binding {
    let title: String
    let key: Int
    /** Carbon modifier bits, as RegisterEventHotKey wants them. */
    let modifiers: UInt32
    let action: () -> Void

    var flags: NSEvent.ModifierFlags {
        [(cmdKey, NSEvent.ModifierFlags.command), (optionKey, .option), (controlKey, .control), (shiftKey, .shift)]
            .reduce(into: []) { flags, pair in if modifiers & UInt32(pair.0) != 0 { flags.insert(pair.1) } }
    }
    var keyEquivalent: String {
        let arrows = [kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey]
        if let arrow = arrows[key] { return String(UnicodeScalar(UInt16(arrow))!) }
        return [kVK_Return: "\r", kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_C: "c", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "="][key] ?? ""
    }
}

extension Tiler {
    // MARK: keyboard

    func focusedID() -> Int? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let window = AXUIElementCreateApplication(app.processIdentifier).value(kAXFocusedWindowAttribute)
        else { return nil }
        return (window as! AXUIElement).windowID
    }

    /** The tile just past `id`'s edge on `zone`'s side, on any display. */
    func neighbour(_ id: Int, _ zone: Zone) -> Int? {
        guard let key = treeKey(of: id), let r = layouts[key]?.panes[id] else { return nil }
        let reach: CGFloat = 10
        let point: CGPoint = switch zone {
        case .left: CGPoint(x: r.minX - reach, y: r.midY)
        case .right: CGPoint(x: r.maxX + reach, y: r.midY)
        case .top: CGPoint(x: r.midX, y: r.minY - reach)
        case .bottom, .center: CGPoint(x: r.midX, y: r.maxY + reach)
        }
        return layouts.values.lazy.compactMap { paneAt($0.panes, point, except: id) }.first
    }

    /** Trades places with the window that way; the layout's shape stays as it is. */
    func moveFocused(_ zone: Zone) {
        guard let id = focusedID(), let target = neighbour(id, zone) else { return }
        move(id, onto: target, .center)
        relayout()
    }

    func focus(_ zone: Zone) {
        guard let id = focusedID(), let target = neighbour(id, zone) else { return }
        raise(target)
    }

    func raise(_ id: Int) {
        guard let window = windows[id] else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    func toggleZoom() {
        guard let id = focusedID(), let window = windows[id] else { return }
        if treeKey(of: id) != nil {
            zoomed = zoomed == id ? nil : id
            relayout()
            raise(id)
        } else if let before = floatZoomed.removeValue(forKey: id) {
            window.setFrame(before)
        } else if let frame = window.frame {
            // a floating window fills the screen and comes back to where it was
            floatZoomed[id] = frame
            window.setFrame(tileArea(screen(containing: CGPoint(x: frame.midX, y: frame.midY))))
        }
    }

    /** Lifts the window out of the tiling, centred; again puts it back where it's dropped. */
    func toggleFloat() {
        guard let id = focusedID(), let window = windows[id], window.isStandard, let frame = window.frame else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if treeKey(of: id) != nil {
            untile(id)
            let area = tileArea(screen(containing: center))
            window.setFrame(area.insetBy(dx: area.width * 0.2, dy: area.height * 0.15))
        } else {
            tile(id, near: layouts.values.lazy.compactMap { paneAt($0.panes, center, except: id) }.first ?? lastFocus)
        }
        relayout()
    }

    /**
     * Pulls the next window in order (or the previous, at the end) in under the
     * focused one; on a window already in a stack, takes it out beside the stack.
     */
    func stackNext() {
        guard let id = focusedID(), let key = treeKey(of: id), let tree = trees[key] else { return }
        if isStacked(tree, id) {
            trees[key] = unstack(tree, id)
            relayout()
            return
        }
        let order = leaves(tree).filter { layouts[key]?.panes[$0] != nil }
        guard let i = order.firstIndex(of: id), order.count > 1 else { return }
        let other = i + 1 < order.count ? order[i + 1] : order[i - 1]
        trees[key] = dropLeaf(tree, other, id, .bottom)
        relayout()
    }

    /** Flips the focused window's group between side by side and stacked. */
    func flipFocused() {
        guard let id = focusedID(), let key = treeKey(of: id), let tree = trees[key], var at = path(to: id, in: tree), at.popLast() != nil else { return }
        trees[key] = flipSplit(tree, at: at[...])
        relayout()
    }

    /**
     * Widens (or narrows) the focused window by `by` of its row, the others giving
     * way in proportion, from its own minimum up to the others all at theirs.
     * Outside any row it changes its height in its stack instead.
     */
    func grow(_ by: CGFloat) {
        guard let id = focusedID(), let key = treeKey(of: id), let tree = trees[key], let panes = layouts[key]?.panes,
              let full = path(to: id, in: tree), !full.isEmpty else { return }
        // the nearest row around it, else its own stack
        let depth = (0..<full.count).last { if case .split(.row, _, _)? = node(at: full.prefix($0), in: tree) { return true } else { return false } } ?? full.count - 1
        let at = full.prefix(depth), i = full[depth]
        guard case let .split(dir, children, sizes)? = node(at: at, in: tree) else { return }
        let row = dir == .row
        let visible = { panes[$0] != nil }
        let shown = children.indices.filter { leaves(children[$0]).contains(where: visible) }
        func extent(_ n: Node) -> CGFloat {
            let rect = leaves(n).compactMap { panes[$0] }.reduce(CGRect.null) { $0.union($1) }
            return row ? rect.width : rect.height
        }
        let length = shown.reduce(0) { $0 + extent(children[$1]) }
        let least = { (j: Int) in minLength(children[j], dir, visible, self.minSize) }
        // Growing squeezes the others below their apps' minimums: they run on under
        // the focused window, which stays on top. Shrinking lets them have it back.
        let others = shown.filter { $0 != i }.flatMap { leaves(children[$0]) }
        if by > 0 { squeezed.formUnion(others) } else { squeezed.subtract(others) }
        // shrinking a window already at its learned minimum tries smaller: the
        // minimum may be stale, and if it's real it's learned again
        if by < 0, extent(children[i]) <= least(i) + 2, case .leaf = children[i] { minSizes[id] = nil }
        let othersLeast = shown.filter { $0 != i }.reduce(0) { $0 + least($1) }
        let target = min(max(extent(children[i]) + by * length, least(i)), length - othersLeast)
        let total = shown.reduce(0) { $0 + sizes[$1] }
        let old = sizes[i], new = Double(target / length) * total
        trees[key] = updatingSizes(tree, at: at) { sizes in
            for j in shown where j != i { sizes[j] *= (total - new) / (total - old) }
            sizes[i] = new
        }
        relayout()
    }

    /** Every shortcut, in the order the menu lists them; `nil` is a separator. */
    var bindings: [Binding?] {
        // ⌘⌥ anchors every shortcut, by the user's choice; ⇧ is the only extra
        let move = UInt32(cmdKey | optionKey), focus = move | UInt32(shiftKey)
        let arrows: [(String, Int, Zone)] = [("Left", kVK_LeftArrow, .left), ("Right", kVK_RightArrow, .right), ("Up", kVK_UpArrow, .top), ("Down", kVK_DownArrow, .bottom)]
        return arrows.map { name, key, zone in Binding(title: "Swap \(name)", key: key, modifiers: move) { self.moveFocused(zone) } }
            + [nil]
            + arrows.map { name, key, zone in Binding(title: "Focus \(name)", key: key, modifiers: focus) { self.focus(zone) } }
            + [nil,
               Binding(title: "Stack Next Window Under / Unstack", key: kVK_ANSI_S, modifiers: move, action: stackNext),
               Binding(title: "Flip Side by Side ⇄ Stacked", key: kVK_ANSI_T, modifiers: move, action: flipFocused),
               Binding(title: "Float / Tile", key: kVK_ANSI_C, modifiers: move, action: toggleFloat),
               Binding(title: "Whole Screen", key: kVK_Return, modifiers: move, action: toggleZoom),
               Binding(title: "Shrink", key: kVK_ANSI_Minus, modifiers: move) { self.grow(-0.1) },
               Binding(title: "Grow", key: kVK_ANSI_Equal, modifiers: move) { self.grow(0.1) }]
    }

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            tiler.bindings[Int(hotKey.id)]?.action()
            return noErr
        }, 1, &spec, nil, nil)
        for (i, binding) in bindings.enumerated() {
            guard let binding else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(binding.key), binding.modifiers, EventHotKeyID(signature: OSType(0x5345_414D), id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
            if status != noErr { print("Seam: \(binding.title) shortcut is taken, turn it off in Raycast") }
        }
    }

    /** The menu lists every shortcut; picking one does it to the focused window. */
    func addShortcuts(to menu: NSMenu) {
        for (i, binding) in bindings.enumerated() {
            guard let binding else { menu.addItem(.separator()); continue }
            let item = menu.addItem(withTitle: binding.title, action: #selector(runBinding(_:)), keyEquivalent: binding.keyEquivalent)
            item.keyEquivalentModifierMask = binding.flags
            item.tag = i
            item.target = self
        }
        menu.addItem(.separator())
        for hint in ["Drag a window onto another: edge splits, middle swaps", "Drag a window's edge to resize"] {
            menu.addItem(withTitle: hint, action: nil, keyEquivalent: "").isEnabled = false
        }
    }

    @objc func runBinding(_ item: NSMenuItem) { bindings[item.tag]?.action() }
}
