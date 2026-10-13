import AppKit
import Carbon.HIToolbox

// Seam: i3-style auto tiling for macOS. Opinionated, no config:
//   ⌘⌥ ←→↑↓     move the window that way      ⌃⌥⇧ ←→↑↓  focus that way
//   ⌘⇧ ↩        zoom (whole screen) toggle     ⌘⌥ C      float / tile toggle
//   ⌃⌥ - / =    shrink / grow                  drag a seam, or a window edge, to resize
//   drag a window onto another: an edge splits it there, the middle swaps the two.

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

var hotKeyActions: [UInt32: () -> Void] = [:]

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
    /** A tiled window the user is moving or resizing with the mouse. */
    var dragging: Int?
    var resizing: Int?
    var drop: (target: Int, zone: Zone)?
    var seamDrag: (screen: CGDirectDisplayID, seam: SeamInfo, start: CGPoint, before: Double, after: Double)?
    let overlay = Tiler.makeOverlay()
    var handles: [NSWindow] = []

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
            // Only the user's own drags: ours happen with the mouse up, or on a seam.
            guard NSEvent.pressedMouseButtons & 1 != 0, seamDrag == nil, let id = element.windowID, id != zoomed, treeKey(of: id) != nil else { return }
            if note == kAXWindowResizedNotification {
                resizing = id
                dragging = nil
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
        for screen in screens {
            let key = key(screen)
            guard let tree = trees[key] else { continue }
            let area = tileArea(screen)
            var out = Layout()
            layout(tree, in: area, visible: visible, into: &out)
            layouts[key] = out
            for (id, rect) in out.panes { place(id, id == zoomed ? area : rect) }
        }
        showHandles()
    }

    func place(_ id: Int, _ rect: CGRect) {
        guard id != dragging, id != resizing, applied[id] != rect else { return }
        windows[id]?.setFrame(rect)
        applied[id] = rect
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
        guard let key = treeKey(of: id), let old = layouts[key]?.panes[id], let seams = layouts[key]?.seams, let new = windows[id]?.frame else { return }
        let edges: [(Dir, CGFloat, CGFloat)] = [
            (.row, old.minX, new.minX), (.row, old.maxX, new.maxX),
            (.column, old.minY, new.minY), (.column, old.maxY, new.maxY),
        ]
        for (dir, was, now) in edges where abs(now - was) > 2 {
            let seam = seams.first { s in
                let row = dir == .row
                let (near, far) = row ? (s.rect.minX, s.rect.maxX) : (s.rect.minY, s.rect.maxY)
                let across = row ? old.midY : old.midX
                let span = row ? s.rect.minY...s.rect.maxY : s.rect.minX...s.rect.maxX
                return s.dir == dir && (abs(near - was) < 2 || abs(far - was) < 2) && span.contains(across)
            }
            guard let seam, let shares = trees[key].flatMap({ sizes(at: seam.path[...], in: $0) }) else { continue }
            shift(key, seam, before: shares[seam.a], after: shares[seam.b], by: now - was)
        }
    }

    func beginSeamDrag(_ screen: CGDirectDisplayID, _ seam: SeamInfo) {
        guard let shares = trees[screen].flatMap({ sizes(at: seam.path[...], in: $0) }) else { return }
        seamDrag = (screen, seam, NSEvent.mouseLocation, shares[seam.a], shares[seam.b])
    }

    func moveSeam() {
        guard let drag = seamDrag else { return }
        let now = NSEvent.mouseLocation
        let px = drag.seam.dir == .row ? now.x - drag.start.x : drag.start.y - now.y
        shift(drag.screen, drag.seam, before: drag.before, after: drag.after, by: px)
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

    // MARK: seam handles and the drop preview

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

    /** A small window in each seam's gap that resizes its two sides when dragged. */
    func showHandles() {
        let zoomedScreen = zoomed.flatMap(treeKey)
        let seams = layouts.sorted { $0.key < $1.key }
            .filter { $0.key != zoomedScreen }
            .flatMap { screen, layout in layout.seams.map { (screen, $0) } }
        while handles.count < seams.count {
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            // below every app window: tiles leave the gap free, a floating window covers it
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.isReleasedWhenClosed = false
            window.contentView = SeamView()
            handles.append(window)
        }
        for (i, window) in handles.enumerated() {
            guard i < seams.count else { window.orderOut(nil); continue }
            (window.contentView as! SeamView).target = seams[i]
            window.setFrame(flip(seams[i].1.rect), display: true)
            window.orderFrontRegardless()
        }
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
        let reach = gap * 3
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
        guard let id = focusedID(), treeKey(of: id) != nil else { return }
        zoomed = zoomed == id ? nil : id
        relayout()
        raise(id)
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

    func registerHotKeys() {
        let hyper = UInt32(controlKey | optionKey), shift = UInt32(shiftKey)
        let order = UInt32(cmdKey | optionKey), command = UInt32(cmdKey)
        let arrows: [(Int, Zone)] = [(kVK_LeftArrow, .left), (kVK_RightArrow, .right), (kVK_UpArrow, .top), (kVK_DownArrow, .bottom)]
        var bindings: [(Int, UInt32, () -> Void)] = [
            (kVK_Return, command | shift, toggleZoom),
            (kVK_ANSI_C, order, toggleFloat),
            (kVK_ANSI_Minus, hyper, { self.grow(-0.05) }),
            (kVK_ANSI_Equal, hyper, { self.grow(0.05) }),
        ]
        for (key, zone) in arrows {
            bindings.append((key, order, { self.moveFocused(zone) }))
            bindings.append((key, hyper | shift, { self.focus(zone) }))
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            hotKeyActions[hotKey.id]?()
            return noErr
        }, 1, &spec, nil, nil)
        for (i, (key, modifiers, action)) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(key), modifiers, EventHotKeyID(signature: OSType(0x5345_414D), id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
            if status != noErr { print("Seam: shortcut \(i) is taken, turn it off in Raycast") }
            hotKeyActions[UInt32(i)] = action
        }
    }

    @objc func retile() {
        trees = [:]
        windows = [:]
        applied = [:]
        zoomed = nil
        sync()
    }
}

/** Draws a faint grip and turns drags into seam moves. */
final class SeamView: NSView {
    var target: (CGDirectDisplayID, SeamInfo)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) {
        (target?.1.dir == .row ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {
        if let (screen, seam) = target { tiler.beginSeamDrag(screen, seam) }
    }
    override func mouseDragged(with event: NSEvent) { tiler.moveSeam() }
    override func mouseUp(with event: NSEvent) { tiler.seamDrag = nil }

    override func draw(_ dirtyRect: NSRect) {
        // fully clear pixels let clicks fall through, so the gap is barely tinted
        NSColor(white: 0.5, alpha: 0.02).setFill()
        bounds.fill()
        NSColor(white: 0.5, alpha: 0.35).setFill()
        let row = target?.1.dir == .row
        let grip = row
            ? NSRect(x: bounds.midX - 1, y: bounds.midY - 20, width: 2, height: 40)
            : NSRect(x: bounds.midX - 20, y: bounds.midY - 1, width: 40, height: 2)
        NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
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
