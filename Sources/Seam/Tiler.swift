import AppKit

/** Apps that never tile (`⌘⌥⇧C`), kept across restarts. */
var floatingApps: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: "floatingApps") ?? ["com.apple.systempreferences", "com.apple.calculator"]) }
    set { UserDefaults.standard.set(newValue.sorted(), forKey: "floatingApps") }
}

// the refcon is the window's ID, so a destroyed window needs no call into its app
let axCallback: AXObserverCallback = { _, element, note, refcon in tiler.handle(note as String, element, refcon.map { Int(bitPattern: $0) }) }

final class Tiler: NSObject {
    var trees: [TreeKey: Node] = [:]
    var layouts: [TreeKey: Layout] = [:]
    var windows: [Int: AXUIElement] = [:]
    /** The frame each tile was last given, so unchanged ones aren't touched. */
    var applied: [Int: CGRect] = [:]
    var observers: [pid_t: AXObserver] = [:]
    var lastFocus: Int?
    /** Cached: asking the frontmost app blocks while it's busy. */
    var focused: Int?
    var zoomed: Int?
    /** Floating windows filling the screen, and the frame each had before. */
    var floatZoomed: [Int: CGRect] = [:]
    /** Per window, the smallest and largest size its app allows, learned by trying. */
    var minSizes: [Int: CGSize] = [:]
    var maxSizes: [Int: CGSize] = [:]
    /** Windows resized since the last min-size check. */
    var unsettled: Set<Int> = []
    /** Windows whose app minimum is ignored because a neighbour grew over them. */
    var squeezed: Set<Int> = []
    /** A lone window's width as a fraction of its display, and its side: -1 left, 0 centre, 1 right. */
    var soloWidth: [Int: CGFloat] = [:]
    var soloSide: [Int: Int] = [:]
    var settle: DispatchWorkItem?
    /** One serial queue per app, so a slow app holds up no other. */
    var queues: [pid_t: DispatchQueue] = [:]
    /** Windows with a frame on its way; their notifications meanwhile are half done. */
    var moving: [Int: Int] = [:]
    var dragging: Int?
    var resizing: Int?
    /** Mouse moved with the button down; a plain click sets no drag. */
    var mouseMoved = false
    var drop: (target: Int, zone: Zone)?
    let overlay = Tiler.makeOverlay()
    let border = Tiler.makeBorder()

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        let workspace = NSWorkspace.shared.notificationCenter
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited { observe(app.pid) }
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.activationPolicy != .prohibited { self.observe(app.pid) }
            self.sync()
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in self.sync() }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            self.border.orderOut(nil)
            self.border.alphaValue = 0
            // apps may have resized their windows on the other Space meanwhile
            let shown = windowList(.optionOnScreenOnly)
            for w in shown {
                guard let id = w[kCGWindowNumber as String] as? Int, let rect = self.applied[id], bounds(w) != rect else { continue }
                self.applied[id] = nil
            }
            self.relayout(onScreen: ids(shown))
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; self.border.animator().alphaValue = 1 }
            DispatchQueue.main.async { self.sync() }
        }
        // an app started through a launcher (Device Hub) announces no windows; its activation is the cue
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            self.focusedID()
            self.sync()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in self.relayout() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { _ in self.mouseDragged() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in self.mouseUp() }
        registerHotKeys()
        focusedID()
        sync()
    }

    // MARK: windows

    /** Picks up unannounced windows, forgets closed ones, lays out. Only apps showing an unknown window are asked (each ask blocks on the app). */
    func sync() {
        let list = windowList(.optionOnScreenOnly)
        var ask = Set<pid_t>()
        for w in list where w[kCGWindowLayer as String] as? Int == 0 {
            guard let id = w[kCGWindowNumber as String] as? Int, windows[id] == nil, let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let r = bounds(w), r.width >= minPane, r.height >= minPane else { continue }
            ask.insert(pid_t(pid))
        }
        for pid in ask where pid != getpid() && NSRunningApplication(processIdentifier: pid)?.activationPolicy != .prohibited {
            for window in AXUIElementCreateApplication(pid).value(kAXWindowsAttribute) as? [AXUIElement] ?? [] { add(window) }
        }
        for (pid, observer) in observers where kill(pid, 0) != 0 && errno == ESRCH {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = nil
        }
        // off screen with no Space: closed. Off screen on another Space: keeps its place
        let onScreen = ids(list)
        for id in Set(windows.keys).union(trees.values.flatMap(leaves)) where !onScreen.contains(id) && spaces(of: [id]).isEmpty { forget(id) }
        // a window moved to another desktop joins that desktop's tree
        for (key, tree) in trees where Set(spaces(of: leaves(tree))) != [key.space] {
            for id in leaves(tree) {
                let on = spaces(of: [id])
                guard on.count == 1, on[0] != key.space else { continue }
                untile(id)
                append(id, to: TreeKey(space: on[0], display: key.display))
            }
        }
        relayout(onScreen: onScreen)
    }

    func add(_ window: AXUIElement) {
        guard let id = window.windowID, windows[id] == nil else { return }
        let pid = window.pid
        observe(pid)
        windows[id] = window
        watch(window, id)
        if treeKey(of: id) == nil, window.isStandard, let frame = windowFrame(id), frame.width >= minPane, frame.height >= minPane,
           !floatingApps.contains(bundle(pid)) { tile(id, near: lastFocus) }
    }

    func observe(_ pid: pid_t) {
        var observer: AXObserver?
        guard pid != getpid(), observers[pid] == nil, AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        for note in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(observer, app, note as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    func watch(_ window: AXUIElement, _ id: Int) {
        guard let observer = observers[window.pid] else { return }
        for note in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, window, note as CFString, UnsafeMutableRawPointer(bitPattern: id))
        }
    }

    /** `watched` is the window's ID for its own notifications, nil for its app's. */
    func handle(_ note: String, _ element: AXUIElement, _ watched: Int?) {
        switch note {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            guard let id = watched else { return }
            // a user drag: mouse down and moving, and the first window touched (neighbours we resize live also notify)
            let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
            if mouseDown, mouseMoved, id != zoomed, treeKey(of: id) != nil, (resizing ?? dragging ?? id) == id {
                userDrags(id, resize: note == kAXWindowResizedNotification)
            } else if !mouseDown, moving[id] == nil {
                appMoved(id, element)
            }
        case kAXFocusedWindowChangedNotification:
            guard let id = element.windowID else { return }
            focused = id
            add(element)
            if treeKey(of: id) != nil { lastFocus = id }
            // an app that hides a window on close sends nothing but this
            relayout()
        case kAXWindowCreatedNotification:
            add(element)
            relayout()
            // not on screen for a moment yet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.relayout() }
        case kAXUIElementDestroyedNotification:
            guard let id = watched else { return }
            forget(id)
            relayout()
        default: // minimised, restored, app hidden or shown
            relayout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.relayout() }
        }
    }

    func userDrags(_ id: Int, resize: Bool) {
        if resize {
            resizing = id
            dragging = nil
            drop = nil
            overlay.orderOut(nil)
            resizeFromEdges(id)
        } else if resizing == nil {
            dragging = id
        }
    }

    /**
     * An app that moved its own tile (Zoom after login) goes back. Smaller than its tile is its choice (VLC's aspect): centred, not fought.
     * ponytail: an app that always moves itself back would ping-pong; cap retries if one does
     */
    func appMoved(_ id: Int, _ window: AXUIElement) {
        guard id != zoomed, let tile = applied[id], let frame = window.frame else { return showFocus() }
        // grown past a learned maximum: it never was one
        if let most = maxSizes[id], frame.width > most.width + 2 || frame.height > most.height + 2 {
            maxSizes[id] = nil
            applied[id] = nil
            return relayout()
        }
        if frame.width < tile.width - 2 || frame.height < tile.height - 2 {
            centre(window, frame, in: tile)
        } else if abs(frame.minX - tile.minX) > 2 || abs(frame.minY - tile.minY) > 2, !window.isFullScreen {
            applied[id] = nil
            return relayout()
        }
        showFocus()
    }

    func treeKey(of id: Int) -> TreeKey? {
        trees.first { path(to: id, in: $0.value) != nil }?.key
    }

    /** Splits the biggest tile on `target`'s display along its longer side; stacks when a column would come out under `minColumn`. */
    func tile(_ id: Int, near target: Int?) {
        if let target, target != id, let key = treeKey(of: target), let tree = trees[key], let panes = layouts[key]?.panes,
           let (target, rect) = panes.filter({ $0.key != id }).max(by: { $0.value.width * $0.value.height < $1.value.width * $1.value.height }) {
            let zone: Zone = rect.width >= rect.height && rect.width / 2 >= minColumn ? .right : .bottom
            trees[key] = insertBeside(tree, target, id, zone)
        } else if let frame = windowFrame(id) {
            var to = shownKey(screen(containing: frame.center), spaces().current)
            if let on = spaces(of: [id]).first { to.space = on }
            append(id, to: to)
        }
    }

    func append(_ id: Int, to key: TreeKey) {
        trees[key] = trees[key].map { appendLeaf($0, id) } ?? .leaf(id)
    }

    func pane(at point: CGPoint, except id: Int) -> Int? {
        layouts.values.lazy.compactMap { paneAt($0.panes, point, except: id) }.first
    }

    func untile(_ id: Int) {
        trees = trees.compactMapValues { removeLeaf($0, id) }
        applied[id] = nil
        if zoomed == id { zoomed = nil }
    }

    func forget(_ id: Int) {
        untile(id)
        windows[id] = nil
        if focused == id { focused = nil }
        floatZoomed[id] = nil
        minSizes[id] = nil
        maxSizes[id] = nil
        squeezed.remove(id)
        soloWidth[id] = nil
        soloSide[id] = nil
    }

    func relayout(onScreen: Set<Int>? = nil) {
        let screens = NSScreen.screens
        let displays = Set(screens.map(\.displayID)), (current, all, fullscreen) = spaces()
        // a gone display's or desktop's windows move to main; sync then sends each where it really is
        let main = shownKey(screens[0], current)
        for (gone, tree) in trees where !displays.contains(gone.display) || !all.contains(gone.space) {
            trees[gone] = nil
            for id in leaves(tree) { append(id, to: main) }
        }
        let onScreen = onScreen ?? ids(windowList([.optionOnScreenOnly, .excludeDesktopElements]))
        let visible = { (id: Int) in onScreen.contains(id) }
        layouts = [:]
        var placed: [Int] = []
        for screen in screens {
            let key = shownKey(screen, current)
            guard let tree = trees[key], !fullscreen.contains(key.space) else { continue }
            let area = tileArea(screen)
            var out = Layout()
            layout(tree, in: area, visible: visible, minSize: minSize, maxSize: maxSize, into: &out)
            layouts[key] = out
            let lone = out.panes.count == 1
            for (id, rect) in out.panes {
                let to = id == zoomed ? area : lone ? solo(id, rect) : rect
                if place(id, to), id != zoomed { placed.append(id) }
            }
        }
        unsettled.formUnion(placed)
        scheduleSettle()
        showFocus()
    }

    func scheduleSettle() {
        settle?.cancel()
        let check = DispatchWorkItem { self.learnMinSizes() }
        settle = check
        // apps that resize late would read as a minimum if checked at once
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
    }

    func showFocus() {
        guard let id = focused, id != zoomed, let rect = layouts.values.lazy.compactMap({ $0.panes[id] }).first else {
            return border.orderOut(nil)
        }
        // the window's real frame, clipped to its screen: an app minimum may spill past the tile
        let area = tileArea(screen(containing: rect.center))
        let frame = flip(windows[id]?.frame.map { $0.intersection(area) }.flatMap { $0.isEmpty ? nil : $0 } ?? rect)
        if border.frame != frame { border.setFrame(frame, display: true) }
        if !border.isVisible { border.orderFrontRegardless() }
    }

    /** A window bigger than its tile has an app minimum; one smaller than a learned minimum never had it. Relays out when anything changed. */
    func learnMinSizes() {
        var learned = false
        guard moving.isEmpty else { return }
        for id in unsettled where id != dragging && id != resizing && !squeezed.contains(id) {
            guard let window = windows[id], let frame = window.frame, let tile = applied[id] else { continue }
            let known = minSizes[id] ?? .zero
            func learn(_ got: CGFloat, _ tile: CGFloat, _ known: CGFloat) -> CGFloat {
                got > tile + 2 || got < known - 2 ? got : known
            }
            let size = CGSize(width: learn(frame.width, tile.width, known.width), height: learn(frame.height, tile.height, known.height))
            if abs(size.width - known.width) > 2 || abs(size.height - known.height) > 2 {
                minSizes[id] = size
                learned = true
            }
            // well short both ways: the app won't let it grow (Device Hub). Short one way is aspect (VLC), a few points is a terminal's grid
            // ponytail: an app still resizing after 0.3s reads as capped; it heals when it grows (`appMoved`) or on ⌘⌥=
            if frame.width < tile.width - 50, frame.height < tile.height - 50, maxSizes[id] != frame.size {
                maxSizes[id] = frame.size
                learned = true
            }
            centre(window, frame, in: tile)
        }
        unsettled = []
        if learned { relayout() } else { showFocus() }
    }

    func centre(_ window: AXUIElement, _ frame: CGRect, in tile: CGRect) {
        let to = CGPoint(x: frame.width < tile.width - 2 ? tile.midX - frame.width / 2 : tile.minX,
                         y: frame.height < tile.height - 2 ? tile.midY - frame.height / 2 : tile.minY)
        guard abs(to.x - frame.minX) > 2 || abs(to.y - frame.minY) > 2 else { return }
        window.setPosition(to)
    }

    /** A lone window's tile, narrowed to its `soloWidth` and put at its `soloSide`. */
    func solo(_ id: Int, _ rect: CGRect) -> CGRect {
        let width = min(rect.width, maxSize(id).width, max(rect.width * (soloWidth[id] ?? 1), minSize(id).width)).rounded()
        let x = rect.minX + ((rect.width - width) * CGFloat((soloSide[id] ?? 0) + 1) / 2).rounded()
        return CGRect(x: x, y: rect.minY, width: width, height: rect.height)
    }

    /** Whether it moved the window. A capped window goes straight to its tile's middle. */
    @discardableResult
    func place(_ id: Int, _ rect: CGRect) -> Bool {
        guard id != dragging, id != resizing, applied[id] != rect else { return false }
        let most = maxSize(id), width = min(rect.width, most.width), height = min(rect.height, most.height)
        applied[id] = rect
        guard let window = windows[id] else { return true }
        let frame = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height), pid = window.pid
        let queue = queues[pid] ?? DispatchQueue(label: "seam.app.\(pid)")
        queues[pid] = queue
        moving[id, default: 0] += 1
        queue.async {
            window.setFrame(frame)
            DispatchQueue.main.async {
                self.moving[id, default: 1] -= 1
                if self.moving[id] == 0 { self.moving[id] = nil }
                guard self.moving.isEmpty else { return }
                self.scheduleSettle()
                self.showFocus()
            }
        }
        return true
    }

    func minSize(_ id: Int) -> CGSize {
        let learned = squeezed.contains(id) ? .zero : minSizes[id] ?? .zero
        return CGSize(width: max(learned.width, minPane), height: max(learned.height, minPane))
    }

    func maxSize(_ id: Int) -> CGSize {
        maxSizes[id] ?? .unbounded
    }

    @objc func retile() {
        trees = [:]
        windows = [:]
        applied = [:]
        minSizes = [:]
        maxSizes = [:]
        squeezed = []
        soloWidth = [:]
        soloSide = [:]
        zoomed = nil
        sync()
    }
}
