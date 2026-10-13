import AppKit
import Carbon.HIToolbox

// Seam: i3-style auto tiling for macOS. Opinionated, no config. Every shortcut is
// ⌘⌥ + a key (see `bindings`, which the menu bar item also lists); drag a window
// onto another to split or swap, drag a window's edge to resize.

/** Apps that always float: they're small panels, not workspaces. */
let floatingApps: Set<String> = ["com.apple.systempreferences", "com.apple.calculator"]

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success ? value : nil
    }
    var windowID: Int? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success ? Int(id) : nil
    }
    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(self, &pid)
        return pid
    }
    var frame: CGRect? {
        guard let p = value(kAXPositionAttribute), let s = value(kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
    func setFrame(_ rect: CGRect) {
        var origin = rect.origin, size = rect.size
        let p = AXValueCreate(.cgPoint, &origin)!, s = AXValueCreate(.cgSize, &size)!
        // size first so moving onto a smaller display isn't clamped, then again
        // because the old position may have capped it
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, s)
    }
    /** A normal, resizable window: not a dialog, sheet, panel or popover. */
    var isStandard: Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(self, kAXSizeAttribute as CFString, &settable)
        return settable.boolValue && value(kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
    }
    var isFullScreen: Bool { value("AXFullScreen") as? Bool == true }
}

/** AppKit is bottom-left origin, Accessibility top-left; the flip is its own inverse. */
func flip(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: NSScreen.screens[0].frame.height - r.maxY, width: r.width, height: r.height)
}
func mouseAX() -> CGPoint {
    let m = NSEvent.mouseLocation
    return CGPoint(x: m.x, y: NSScreen.screens[0].frame.height - m.y)
}
func key(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}
func screen(containing point: CGPoint) -> NSScreen {
    NSScreen.screens.first { flip($0.frame).contains(point) } ?? NSScreen.screens[0]
}
func tileArea(_ screen: NSScreen) -> CGRect { flip(screen.visibleFrame).insetBy(dx: gap, dy: gap) }

let axCallback: AXObserverCallback = { _, element, note, _ in tiler.handle(note as String, element) }

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

final class Tiler: NSObject {
    /** One tree per display. */
    var trees: [CGDirectDisplayID: Node] = [:]
    var layouts: [CGDirectDisplayID: Layout] = [:]
    var windows: [Int: AXUIElement] = [:]
    /** The frame each tile was last given, so unchanged ones aren't touched. */
    var applied: [Int: CGRect] = [:]
    var observers: [pid_t: AXObserver] = [:]
    var lastFocus: Int?
    var zoomed: Int?
    /** Floating windows filling the screen, and the frame each had before. */
    var floatZoomed: [Int: CGRect] = [:]
    /** The smallest size each window's app has allowed it, learned by trying. */
    var minSizes: [Int: CGSize] = [:]
    /** A tiled window the user is moving or resizing with the mouse. */
    var dragging: Int?
    var resizing: Int?
    var drop: (target: Int, zone: Zone)?
    let overlay = Tiler.makeOverlay()

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in self.sync() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in self.relayout() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { _ in self.mouseDragged() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in self.mouseUp() }
        registerHotKeys()
        sync()
    }

    // MARK: windows

    /** Picks up new windows, forgets closed ones, and lays everything out. */
    func sync() {
        var seen = Set<Int>()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in apps {
            let pid = app.processIdentifier
            if observers[pid] == nil { observe(pid) }
            let appWindows = AXUIElementCreateApplication(pid).value(kAXWindowsAttribute) as? [AXUIElement] ?? []
            for window in appWindows {
                guard let id = window.windowID else { continue }
                seen.insert(id)
                if windows[id] != nil { continue }
                windows[id] = window
                watch(window, pid)
                if window.isStandard && !floatingApps.contains(app.bundleIdentifier ?? "") { tile(id, near: lastFocus) }
            }
        }
        let live = Set(apps.map(\.processIdentifier))
        for (pid, observer) in observers where !live.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = nil
        }
        // ponytail: Accessibility only lists the current Space's windows, so one
        // on another Space is forgotten and re-tiled when you come back
        for id in Array(windows.keys) where !seen.contains(id) { forget(id) }
        relayout()
    }

    func observe(_ pid: pid_t) {
        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        for note in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(observer, app, note as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    func watch(_ window: AXUIElement, _ pid: pid_t) {
        guard let observer = observers[pid] else { return }
        for note in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, window, note as CFString, nil)
        }
    }

    func handle(_ note: String, _ element: AXUIElement) {
        switch note {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // Only the user's own drag of one window: ours happen with the mouse
            // up, or are the neighbours given way to a live edge resize.
            guard NSEvent.pressedMouseButtons & 1 != 0, let id = element.windowID, id != zoomed, treeKey(of: id) != nil,
                  (resizing ?? dragging ?? id) == id else { return }
            if note == kAXWindowResizedNotification {
                resizing = id
                dragging = nil
                drop = nil
                overlay.orderOut(nil)
                // the neighbours follow the edge as it's dragged
                resizeFromEdges(id)
            } else if resizing == nil {
                dragging = id
            }
        case kAXFocusedWindowChangedNotification:
            guard let id = element.windowID else { return }
            if windows[id] == nil { sync() }
            if treeKey(of: id) != nil { lastFocus = id }
        default:
            sync()
            // a new or restored window may not be on screen for a moment yet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.relayout() }
        }
    }

    func treeKey(of id: Int) -> CGDirectDisplayID? {
        trees.first { leaves($0.value).contains(id) }?.key
    }

    /** Beside `target`, splitting it along its longer side, like i3 on a new window. */
    func tile(_ id: Int, near target: Int?) {
        if let target, target != id, let key = treeKey(of: target), let rect = layouts[key]?.panes[target] {
            trees[key] = insertBeside(trees[key]!, target, id, rect.width >= rect.height ? .right : .bottom)
        } else if let frame = windows[id]?.frame {
            let key = key(screen(containing: CGPoint(x: frame.midX, y: frame.midY)))
            trees[key] = trees[key].map { appendLeaf($0, id) } ?? .leaf(id)
        }
    }

    func untile(_ id: Int) {
        trees = trees.compactMapValues { removeLeaf($0, id) }
        applied[id] = nil
        if zoomed == id { zoomed = nil }
    }

    func forget(_ id: Int) {
        untile(id)
        windows[id] = nil
        floatZoomed[id] = nil
        minSizes[id] = nil
    }

    func onScreenIDs() -> Set<Int> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    func relayout() {
        let screens = NSScreen.screens
        let keys = Set(screens.map(key))
        // a disconnected display's windows move to the main one
        for (gone, tree) in trees where !keys.contains(gone) {
            trees[gone] = nil
            let main = key(screens[0])
            for id in leaves(tree) { trees[main] = trees[main].map { appendLeaf($0, id) } ?? .leaf(id) }
        }
        let onScreen = onScreenIDs()
        let visible = { (id: Int) in onScreen.contains(id) && self.windows[id]?.isFullScreen != true }
        layouts = [:]
        var placed: [Int] = []
        for screen in screens {
            let key = key(screen)
            guard let tree = trees[key] else { continue }
            let area = tileArea(screen)
            var out = Layout()
            layout(tree, in: area, visible: visible, minSize: { self.minSizes[$0] ?? .zero }, into: &out)
            layouts[key] = out
            for (id, rect) in out.panes where place(id, id == zoomed ? area : rect) && id != zoomed { placed.append(id) }
        }
        // An app with a minimum size comes out bigger than its tile; remember that
        // minimum and lay out again so its neighbours make room. Minimums only grow,
        // so this settles.
        var learned = false
        for id in placed {
            guard let frame = windows[id]?.frame, let tile = applied[id] else { continue }
            let known = minSizes[id] ?? .zero
            let size = CGSize(width: frame.width > tile.width + 2 ? frame.width : known.width,
                              height: frame.height > tile.height + 2 ? frame.height : known.height)
            if size.width > known.width + 2 || size.height > known.height + 2 {
                minSizes[id] = size
                learned = true
            }
        }
        if learned { relayout() }
    }

    /** Whether it moved the window. */
    @discardableResult
    func place(_ id: Int, _ rect: CGRect) -> Bool {
        guard id != dragging, id != resizing, applied[id] != rect else { return false }
        windows[id]?.setFrame(rect)
        applied[id] = rect
        return true
    }

    // MARK: mouse

    func mouseDragged() {
        guard let dragging else { return }
        let point = mouseAX()
        for layout in layouts.values {
            if let target = paneAt(layout.panes, point, except: dragging), let rect = layout.panes[target] {
                let zone = zoneAt(rect, point)
                drop = (target, zone)
                overlay.setFrame(flip(zoneRect(rect, zone)), display: true)
                overlay.orderFrontRegardless()
                return
            }
        }
        drop = nil
        overlay.orderOut(nil)
    }

    func mouseUp() {
        guard dragging != nil || resizing != nil else { return }
        if let id = dragging, let drop { move(id, onto: drop.target, drop.zone) }
        if let id = resizing { resizeFromEdges(id) }
        // whatever it was dropped on, it snaps into its tile
        for id in [dragging, resizing].compactMap({ $0 }) { applied[id] = nil }
        dragging = nil
        resizing = nil
        drop = nil
        overlay.orderOut(nil)
        relayout()
    }

    func move(_ id: Int, onto target: Int, _ zone: Zone) {
        guard let from = treeKey(of: id), let to = treeKey(of: target) else { return }
        if from == to {
            trees[to] = dropLeaf(trees[to]!, id, target, zone)
        } else {
            // across displays there's nothing to swap with, so the middle means beside
            trees[from] = trees[from].flatMap { removeLeaf($0, id) }
            trees[to] = insertBeside(trees[to]!, target, id, zone == .center ? .right : zone)
        }
    }

    /** Dragging a tile's edge moves the seam on that side, as dragging the seam would. */
    func resizeFromEdges(_ id: Int) {
        guard let key = treeKey(of: id), let old = layouts[key]?.panes[id], let new = windows[id]?.frame else { return }
        let edges: [(Dir, CGFloat, CGFloat)] = [
            (.row, old.minX, new.minX), (.row, old.maxX, new.maxX),
            (.column, old.minY, new.minY), (.column, old.maxY, new.maxY),
        ]
        for (dir, was, now) in edges where abs(now - was) > 2 {
            if let seam = seam(key, beside: old, dir, at: was) { moveSeam(key, seam, by: now - was) }
        }
    }

    /** The seam running along `tile`'s edge at `edge`. */
    func seam(_ key: CGDirectDisplayID, beside tile: CGRect, _ dir: Dir, at edge: CGFloat) -> SeamInfo? {
        layouts[key]?.seams.first { s in
            let row = dir == .row
            let (near, far) = row ? (s.rect.minX, s.rect.maxX) : (s.rect.minY, s.rect.maxY)
            let across = row ? tile.midY : tile.midX
            let span = row ? s.rect.minY...s.rect.maxY : s.rect.minX...s.rect.maxX
            return s.dir == dir && (abs(near - edge) < 2 || abs(far - edge) < 2) && span.contains(across)
        }
    }

    func moveSeam(_ key: CGDirectDisplayID, _ seam: SeamInfo, by px: CGFloat) {
        guard let shares = trees[key].flatMap({ sizes(at: seam.path[...], in: $0) }) else { return }
        shift(key, seam, before: shares[seam.a], after: shares[seam.b], by: px)
    }

    /** Trades `px` of room between the seam's two sides; both stop at their minimums. */
    func shift(_ screen: CGDirectDisplayID, _ seam: SeamInfo, before: Double, after: Double, by px: CGFloat) {
        let pair = before + after
        let least = Double(minPane / seam.pxPerShare)
        let size = min(max(before + Double(px / seam.pxPerShare), least), pair - least)
        trees[screen] = trees[screen].map {
            updatingSizes($0, at: seam.path[...]) { sizes in
                sizes[seam.a] = size
                sizes[seam.b] = pair - size
            }
        }
        relayout()
    }

    // MARK: the drop preview

    static func makeOverlay() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.isReleasedWhenClosed = false
        return window
    }

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

    func moveFocused(_ zone: Zone) {
        guard let id = focusedID(), let target = neighbour(id, zone) else { return }
        move(id, onto: target, zone)
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

    /** Pulls the next window in order (or the previous, at the end) in under the focused one. */
    func stackNext() {
        guard let id = focusedID(), let key = treeKey(of: id), let tree = trees[key] else { return }
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

    /** Grows the focused window's share in its split; the others give way evenly. */
    func grow(_ by: Double) {
        guard let id = focusedID(), let key = treeKey(of: id), let tree = trees[key], var at = path(to: id, in: tree), let i = at.popLast() else { return }
        trees[key] = updatingSizes(tree, at: at[...]) { sizes in
            let old = sizes[i], new = min(max(old + by, 0.1), 0.9)
            for j in sizes.indices where j != i { sizes[j] *= (1 - new) / (1 - old) }
            sizes[i] = new
        }
        relayout()
    }

    /** Every shortcut, in the order the menu lists them; `nil` is a separator. */
    lazy var bindings: [Binding?] = {
        // ⌘⌥ anchors every shortcut, by the user's choice; ⇧ is the only extra
        let move = UInt32(cmdKey | optionKey), focus = move | UInt32(shiftKey)
        let arrows: [(String, Int, Zone)] = [("Left", kVK_LeftArrow, .left), ("Right", kVK_RightArrow, .right), ("Up", kVK_UpArrow, .top), ("Down", kVK_DownArrow, .bottom)]
        return arrows.map { name, key, zone in Binding(title: "Move \(name)", key: key, modifiers: move) { self.moveFocused(zone) } }
            + [nil]
            + arrows.map { name, key, zone in Binding(title: "Focus \(name)", key: key, modifiers: focus) { self.focus(zone) } }
            + [nil,
               Binding(title: "Stack Next Window Under", key: kVK_ANSI_S, modifiers: move, action: stackNext),
               Binding(title: "Flip Side by Side ⇄ Stacked", key: kVK_ANSI_T, modifiers: move, action: flipFocused),
               Binding(title: "Float / Tile", key: kVK_ANSI_C, modifiers: move, action: toggleFloat),
               Binding(title: "Whole Screen", key: kVK_Return, modifiers: move, action: toggleZoom),
               Binding(title: "Shrink", key: kVK_ANSI_Minus, modifiers: move) { self.grow(-0.05) },
               Binding(title: "Grow", key: kVK_ANSI_Equal, modifiers: move) { self.grow(0.05) }]
    }()

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

    @objc func retile() {
        trees = [:]
        windows = [:]
        applied = [:]
        zoomed = nil
        sync()
    }
}

if CommandLine.arguments.contains("--selftest") {
    treeSelfTest()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tiler = Tiler()

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Seam")
let menu = NSMenu()
tiler.addShortcuts(to: menu)
menu.addItem(.separator())
menu.addItem(withTitle: "Retile Everything", action: #selector(Tiler.retile), keyEquivalent: "").target = tiler
menu.addItem(.separator())
menu.addItem(NSMenuItem(title: "Quit Seam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
statusItem.menu = menu

if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
    tiler.start()
} else {
    // starts as soon as it's allowed in System Settings › Privacy › Accessibility
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
        guard AXIsProcessTrusted() else { return }
        timer.invalidate()
        tiler.start()
    }
}
app.run()
