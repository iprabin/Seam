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
    /** The workspace showing on each display and Space, keyed with workspace 1; 1 if absent. */
    var active: [TreeKey: Int] = [:]
    /** The frame each window came with, to give back if it turns out not to tile. */
    var born: [Int: CGRect] = [:]
    /** Windows of hidden workspaces, waiting at `parkingSpot`. */
    var parked: Set<Int> = []
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
    /** The empty display under a drag. */
    var dropDisplay: TreeKey?
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
            self.reveal(self.focusedID())
            self.sync()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            self.relayout()
            // macOS shuffles windows for a moment after, and a parking spot may now be on a display
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.applied = [:]
                self.parked = []
                self.relayout()
            }
        }
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
        // made always-on-top after it was tiled
        let tiled = Set(trees.values.flatMap(leaves))
        for w in list where w[kCGWindowLayer as String] as? Int != 0 {
            if let id = w[kCGWindowNumber as String] as? Int, tiled.contains(id) { release(id) }
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
                if on.count > 1 { release(id) } // now on every desktop: floats, as in yabai
                guard on.count == 1, on[0] != key.space, !parked.contains(id) else { continue }
                // the display it's on now: dragged to another, its Space changed with it
                let display = windowFrame(id).map { screen(containing: $0.center).displayID } ?? key.display
                untile(id)
                append(id, to: shown(TreeKey(space: on[0], display: display)))
            }
        }
        relayout(onScreen: onScreen)
    }

    func add(_ window: AXUIElement) {
        guard let id = window.windowID, windows[id] == nil else { return }
        let pid = window.pid
        #if E2E
        guard e2eOnly.contains(pid) else { return }
        #endif
        observe(pid)
        windows[id] = window
        watch(window, id)
        born[id] = window.frame
        // a moment's grace: apps raise a new window above the normal level, or pin it to every desktop, only after creating it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.adopt(id, window) }
    }

    func adopt(_ id: Int, _ window: AXUIElement) {
        // the AX frame: the window server has nothing yet for a window just created
        guard windows[id] != nil, treeKey(of: id) == nil, window.isStandard, let frame = window.frame, frame.width >= minPane, frame.height >= minPane,
              !floatingApps.contains(bundle(window.pid)) else { return }
        tile(id, near: lastFocus)
        // asked, not the cached `focused`: a background app's focus event may have just replaced it
        if focusedID() == id {
            lastFocus = id
            reveal(id)
        }
        relayout()
    }

    /** Out of the tiling for good, as it came. */
    func release(_ id: Int) {
        untile(id)
        if let frame = born[id] { windows[id]?.setFrame(frame) }
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
            add(element)
            // a background app's own focus isn't the user's; an app coming forward is picked up by its activation
            if element.pid == NSWorkspace.shared.frontmostApplication?.pid {
                focused = id
                if treeKey(of: id) != nil { lastFocus = id }
                reveal(id)
            }
            // an app that hides a window on close sends nothing but this
            relayout()
        case kAXWindowCreatedNotification:
            add(element)
            relayout()
            // not on screen for a moment yet, and some apps only then raise it above the normal level
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.sync() }
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

    /** Into the workspace showing where `target` is, unless the window opened on another Space or display: then there. */
    func tile(_ id: Int, near target: Int?) {
        let on = spaces(of: [id]).first
        if let target, let key = treeKey(of: target), on == nil || on == key.space {
            append(id, to: shown(key))
        } else if let frame = windows[id]?.frame {
            var to = shownKey(screen(containing: frame.center), spaces().current)
            if let on { to.space = on }
            append(id, to: shown(to))
        }
    }

    /** Full, it goes on to the next workspace with room. Laid out afresh: `layouts` lags several windows added at once, and has no other Space. */
    func append(_ id: Int, to key: TreeKey) {
        var key = key
        key.workspace = workspaceWithRoom(from: key.workspace) { n in
            var at = key
            at.workspace = n
            return trees[at].map { leaves($0).count } ?? 0
        }
        guard let tree = trees[key] else { trees[key] = .leaf(id); return }
        let area = tileArea(NSScreen.screens.first { $0.displayID == key.display } ?? NSScreen.screens[0])
        let shown = ids(windowList(.optionOnScreenOnly)).intersection(leaves(tree))
        trees[key] = addWindow(tree, id, in: area) { shown.isEmpty || shown.contains($0) }
    }

    /** `key` with the workspace showing there. */
    func shown(_ key: TreeKey) -> TreeKey {
        var base = key
        base.workspace = 1
        var key = base
        key.workspace = active[base] ?? 1
        return key
    }

    /** A workspace lives only while it has windows: emptied, the closest one left shows. */
    func leaveIfEmpty(_ base: TreeKey) {
        let at = shown(base)
        guard trees[at] == nil else { return }
        let occupied = trees.keys.filter { $0.space == at.space && $0.display == at.display }.map(\.workspace)
        active[base] = nearestWorkspace(to: at.workspace, among: occupied)
        if let first = trees[shown(base)].flatMap({ leaves($0).first }) { raise(first) }
    }

    /** Focus landed in a hidden workspace (Dock, ⌘Tab, a fifth window opening): that workspace shows, like i3. The caller lays out. */
    func reveal(_ id: Int?) {
        guard let id, let key = treeKey(of: id), shown(key) != key, windows[id]?.pid == NSWorkspace.shared.frontmostApplication?.pid else { return }
        var base = key
        base.workspace = 1
        active[base] = key.workspace
    }

    func pane(at point: CGPoint, except id: Int) -> Int? {
        layouts.values.lazy.compactMap { paneAt($0.panes, point, except: id) }.first
    }

    func untile(_ id: Int) {
        trees = trees.compactMapValues { removeLeaf($0, id) }
        applied[id] = nil
        parked.remove(id)
        if zoomed == id { zoomed = nil }
    }

    func forget(_ id: Int) {
        untile(id)
        windows[id] = nil
        born[id] = nil
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
        let main = shown(shownKey(screens[0], current))
        for (gone, tree) in trees where !displays.contains(gone.display) || !all.contains(gone.space) {
            trees[gone] = nil
            for id in leaves(tree) { append(id, to: main) }
        }
        for screen in screens { leaveIfEmpty(shownKey(screen, current)) }
        let onScreen = onScreen ?? ids(windowList([.optionOnScreenOnly, .excludeDesktopElements]))
        let visible = { (id: Int) in onScreen.contains(id) }
        layouts = [:]
        var placed: [Int] = []
        for screen in screens {
            let key = shown(shownKey(screen, current))
            guard let tree = trees[key], !fullscreen.contains(key.space) else { continue }
            let area = tileArea(screen)
            var out = Layout()
            layout(tree, in: area, visible: visible, minSize: minSize, maxSize: maxSize, into: &out)
            layouts[key] = out
            let lone = out.panes.count == 1
            for (id, rect) in out.panes {
                let to = id == zoomed ? area : lone ? solo(id, rect) : rect
                parked.remove(id)
                if place(id, to), id != zoomed { placed.append(id) }
            }
        }
        for (key, tree) in trees where shown(key) != key {
            for id in leaves(tree) where !parked.contains(id) { park(id, on: key.display) }
        }
        statusItem.button?.title = String(shown(shownKey(screen(containing: mouseAX()), current)).workspace)
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
        let frame = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        send(id, window) { $0.setFrame(frame) }
        return true
    }

    func park(_ id: Int, on display: CGDirectDisplayID) {
        guard let window = windows[id] else { return }
        parked.insert(id)
        applied[id] = nil // its tile is gone; coming back it's placed afresh
        let frames = NSScreen.screens.map { ($0.displayID, flip($0.frame)) }
        let own = frames.first { $0.0 == display }?.1 ?? frames[0].1, others = frames.filter { $0.0 != display }.map(\.1)
        send(id, window) { window in
            window.setPosition(parkingSpot(own, others: others, size: window.frame?.size ?? .zero))
        }
    }

    /** Off the main thread, in order per app. */
    func send(_ id: Int, _ window: AXUIElement, _ change: @escaping (AXUIElement) -> Void) {
        let pid = window.pid
        let queue = queues[pid] ?? DispatchQueue(label: "seam.app.\(pid)")
        queues[pid] = queue
        moving[id, default: 0] += 1
        queue.async {
            change(window)
            DispatchQueue.main.async {
                self.moving[id, default: 1] -= 1
                if self.moving[id] == 0 { self.moving[id] = nil }
                guard self.moving.isEmpty else { return }
                self.scheduleSettle()
                self.showFocus()
            }
        }
    }

    /** Quitting: nothing would bring them back from off screen. Blocks, the app is about to go. */
    func unparkAll() {
        let home = tileArea(NSScreen.screens[0]).origin
        for id in parked { windows[id]?.setPosition(home) }
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
        active = [:]
        parked = []
        born = [:]
        soloWidth = [:]
        soloSide = [:]
        zoomed = nil
        sync()
    }
}
