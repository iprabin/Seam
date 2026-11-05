import AppKit
import Carbon.HIToolbox

struct Binding {
    let title: String
    let key: Int
    /** Carbon modifier bits, as RegisterEventHotKey wants them. */
    let modifiers: UInt32
    /** The workspace keys are one hint line, not 18 rows. */
    var inMenu = true
    let action: () -> Void

    var flags: NSEvent.ModifierFlags {
        [(cmdKey, NSEvent.ModifierFlags.command), (optionKey, .option), (controlKey, .control), (shiftKey, .shift)]
            .reduce(into: []) { flags, pair in if modifiers & UInt32(pair.0) != 0 { flags.insert(pair.1) } }
    }
    var keyEquivalent: String {
        let arrows = [kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey]
        if let arrow = arrows[key] { return String(UnicodeScalar(UInt16(arrow))!) }
        return [kVK_Return: "\r", kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_C: "c", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_0: "0"][key] ?? ""
    }
}

extension Tiler {
    // MARK: keyboard

    /** Asks the frontmost app (blocks on it), so only on a user action or app switch. */
    @discardableResult
    func focusedID() -> Int? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let window = AXUIElementCreateApplication(app.pid).value(kAXFocusedWindowAttribute),
              CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        focused = (window as! AXUIElement).windowID
        return focused
    }

    /** The tile just past `id`'s edge, on any display. */
    func neighbour(_ id: Int, _ zone: Zone) -> Int? {
        guard let key = treeKey(of: id), let r = layouts[key]?.panes[id] else { return nil }
        return pane(at: past(r, zone), except: id)
    }

    func past(_ r: CGRect, _ zone: Zone) -> CGPoint {
        let reach: CGFloat = 10
        return switch zone {
        case .left: CGPoint(x: r.minX - reach, y: r.midY)
        case .right: CGPoint(x: r.maxX + reach, y: r.midY)
        case .top: CGPoint(x: r.midX, y: r.minY - reach)
        case .bottom, .center: CGPoint(x: r.midX, y: r.maxY + reach)
        }
    }

    /** The display beyond the window's own that way, if it's there. */
    func displayKey(past id: Int, _ zone: Zone) -> TreeKey? {
        guard let key = treeKey(of: id), let own = NSScreen.screens.first(where: { $0.displayID == key.display }) else { return nil }
        let point = past(flip(own.frame), zone)
        return NSScreen.screens.first { flip($0.frame).contains(point) }.map { shown(shownKey($0, spaces().current)) }
    }

    /** Swaps with the window that way; a narrowed lone window steps left / centre / right first. */
    func moveFocused(_ zone: Zone) {
        guard let id = focusedID() else { return }
        let step = zone == .left ? -1 : zone == .right ? 1 : 0, side = (soloSide[id] ?? 0) + step
        if step != 0, (-1...1).contains(side), let key = treeKey(of: id), let panes = layouts[key]?.panes, panes.count == 1,
           let area = panes[id], solo(id, area).width < area.width {
            soloSide[id] = side
            return relayout()
        }
        if let target = neighbour(id, zone) {
            move(id, onto: target, .center)
        } else if let key = displayKey(past: id, zone) { // no tile there: an empty display
            moveTo(id, key)
        }
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
            floatZoomed[id] = frame
            window.setFrame(tileArea(screen(containing: frame.center)))
        }
    }

    /** Out of the tiling, centred; or back in, where it sits. */
    func toggleFloat() {
        guard let id = focusedID(), let window = windows[id], window.isStandard, let frame = window.frame else { return }
        if treeKey(of: id) != nil {
            untile(id)
            let area = tileArea(screen(containing: frame.center))
            window.setFrame(area.insetBy(dx: area.width * 0.2, dy: area.height * 0.15))
        } else {
            tile(id, near: pane(at: frame.center, except: id) ?? lastFocus)
        }
        relayout()
    }

    func toggleAppFloat() {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return }
        let off = !floatingApps.contains(bundle), pid = app.pid
        if off { floatingApps.insert(bundle) } else { floatingApps.remove(bundle) }
        for (id, window) in windows where window.pid == pid && window.isStandard && (treeKey(of: id) != nil) == off {
            if off { untile(id) } else { tile(id, near: lastFocus) }
        }
        relayout()
    }

    /** Pulls the next window (previous, at the end) under the focused one; on a stacked window, unstacks it. */
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

    func flipFocused() {
        guard let id = focusedID(), let key = treeKey(of: id), let tree = trees[key], var at = path(to: id, in: tree), at.popLast() != nil else { return }
        trees[key] = flipSplit(tree, at: at[...])
        relayout()
    }

    /** Widens the focused window by `by` of its nearest row (its stack, outside any row), the others giving way in proportion. Alone on its display it narrows about its middle. */
    func grow(_ by: CGFloat) {
        guard let id = focusedID(), let key = treeKey(of: id), let tree = trees[key], let panes = layouts[key]?.panes else { return }
        if panes.count == 1, let area = panes[id] {
            soloWidth[id] = min(max((soloWidth[id] ?? 1) + by, minSize(id).width / area.width), 1)
            return relayout()
        }
        guard let full = path(to: id, in: tree), !full.isEmpty else { return }
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
        // growing squeezes the others under their app minimums; shrinking gives them back
        let others = shown.filter { $0 != i }.flatMap { leaves(children[$0]) }
        if by > 0 { squeezed.formUnion(others) } else { squeezed.subtract(others) }
        // a learned limit in the way is forgotten and relearned if real
        if by > 0 { maxSizes[id] = nil }
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

    /** The display under the mouse shows workspace `n`, if it has windows: an empty one doesn't exist. */
    func goTo(_ n: Int) {
        let base = shownKey(screen(containing: mouseAX()), spaces().current)
        var to = base
        to.workspace = n
        guard shown(base) != to, trees[to] != nil else { return }
        active[base] = n
        relayout()
        if let first = trees[shown(base)].flatMap({ leaves($0).first }) { raise(first) }
    }

    /** Sends the focused window to workspace `n`, staying here, as i3 does. */
    func send(toWorkspace n: Int) {
        guard let id = focusedID(), var key = treeKey(of: id), key.workspace != n else { return }
        key.workspace = n
        untile(id)
        append(id, to: key)
        relayout()
    }

    func balance() {
        guard let id = focusedID(), let key = treeKey(of: id), let tree = trees[key] else { return }
        trees[key] = balanced(tree)
        squeezed.subtract(leaves(tree))
        for id in leaves(tree) { soloWidth[id] = nil; soloSide[id] = nil }
        relayout()
    }

    /** Every shortcut in menu order; `nil` is a separator. All are ⌘⌥, ⇧ the only extra, by the user's rule. */
    var bindings: [Binding?] {
        let move = UInt32(cmdKey | optionKey), focus = move | UInt32(shiftKey)
        let app = NSWorkspace.shared.frontmostApplication, name = app?.localizedName ?? "This App"
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let arrows: [(String, Int, Zone)] = [("Left", kVK_LeftArrow, .left), ("Right", kVK_RightArrow, .right), ("Up", kVK_UpArrow, .top), ("Down", kVK_DownArrow, .bottom)]
        return arrows.map { name, key, zone in Binding(title: "Swap \(name)", key: key, modifiers: move) { self.moveFocused(zone) } }
            + [nil]
            + arrows.map { name, key, zone in Binding(title: "Focus \(name)", key: key, modifiers: focus) { self.focus(zone) } }
            + [nil,
               Binding(title: "Stack Next Window Under / Unstack", key: kVK_ANSI_S, modifiers: move, action: stackNext),
               Binding(title: "Flip Side by Side ⇄ Stacked", key: kVK_ANSI_T, modifiers: move, action: flipFocused),
               Binding(title: "Float / Tile Window", key: kVK_ANSI_C, modifiers: move, action: toggleFloat),
               Binding(title: floatingApps.contains(app?.bundleIdentifier ?? "") ? "Tile \(name) Again" : "Never Tile \(name)",
                       key: kVK_ANSI_C, modifiers: focus, action: toggleAppFloat),
               Binding(title: "Whole Screen", key: kVK_Return, modifiers: move, action: toggleZoom),
               Binding(title: "Shrink", key: kVK_ANSI_Minus, modifiers: move) { self.grow(-0.1) },
               Binding(title: "Grow", key: kVK_ANSI_Equal, modifiers: move) { self.grow(0.1) },
               Binding(title: "Even Out", key: kVK_ANSI_0, modifiers: move, action: balance)]
            + digits.enumerated().flatMap { i, key in
                [Binding(title: "Workspace \(i + 1)", key: key, modifiers: move, inMenu: false) { self.goTo(i + 1) },
                 Binding(title: "Send to Workspace \(i + 1)", key: key, modifiers: focus, inMenu: false) { self.send(toWorkspace: i + 1) }]
            }
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
            let seam = OSType(0x5345_414D) // "SEAM"
            let status = RegisterEventHotKey(UInt32(binding.key), binding.modifiers, EventHotKeyID(signature: seam, id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
            if status != noErr { print("Seam: \(binding.title) shortcut is taken, turn it off in Raycast") }
        }
    }

    func addShortcuts(to menu: NSMenu) {
        for (i, binding) in bindings.enumerated() {
            guard let binding else { menu.addItem(.separator()); continue }
            guard binding.inMenu else { continue }
            let item = menu.addItem(withTitle: binding.title, action: #selector(runBinding(_:)), keyEquivalent: binding.keyEquivalent)
            item.keyEquivalentModifierMask = binding.flags
            item.tag = i
            item.target = self
        }
        menu.addItem(.separator())
        for hint in ["⌘⌥1–9 switch workspace, ⌘⌥⇧1–9 send the window there", "Drag a window onto another: edge splits, middle swaps", "Drag a window's edge to resize"] {
            menu.addItem(withTitle: hint, action: nil, keyEquivalent: "").isEnabled = false
        }
    }

    @objc func runBinding(_ item: NSMenuItem) { bindings[item.tag]?.action() }
}

extension Tiler: NSMenuDelegate {
    /** Some titles name the frontmost app. */
    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = bindings
        for item in menu.items where item.action == #selector(runBinding(_:)) { item.title = current[item.tag]?.title ?? item.title }
    }
}
