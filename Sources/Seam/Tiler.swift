import AppKit

/** Apps that never tile: small panels by default, plus any the user turns off (`⌘⌥⇧C`); kept across restarts. */
var floatingApps: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: "floatingApps") ?? ["com.apple.systempreferences", "com.apple.calculator"]) }
    set { UserDefaults.standard.set(newValue.sorted(), forKey: "floatingApps") }
}

// a window's own notifications carry its ID (as yabai does), so even a destroyed one needs no call into its app
let axCallback: AXObserverCallback = { _, element, note, refcon in tiler.handle(note as String, element, refcon.map { Int(bitPattern: $0) }) }

final class Tiler: NSObject {
    /** One tree per Space per display. */
    var trees: [TreeKey: Node] = [:]
    var layouts: [TreeKey: Layout] = [:]
    var windows: [Int: AXUIElement] = [:]
    /** The frame each tile was last given, so unchanged ones aren't touched. */
    var applied: [Int: CGRect] = [:]
    var observers: [pid_t: AXObserver] = [:]
    var lastFocus: Int?
    /** The focused window as last announced: asking the frontmost app each time blocks Seam while it's busy. */
    var focused: Int?
    var zoomed: Int?
    /** Floating windows filling the screen, and the frame each had before. */
    var floatZoomed: [Int: CGRect] = [:]
    /** The smallest size each window's app has allowed it, learned by trying. */
    var minSizes: [Int: CGSize] = [:]
    /** The largest size each window's app lets it have (Device Hub's device view), learned the same way. */
    var maxSizes: [Int: CGSize] = [:]
    /** Windows resized since the last minimum-size check, and that pending check. */
    var unsettled: Set<Int> = []
    /** Windows made to give up room below their app's minimum by growing a neighbour. */
    var squeezed: Set<Int> = []
    /** How much of the screen's width a window narrowed while alone on it keeps, when alone. */
    var soloWidth: [Int: CGFloat] = [:]
    /** Where that narrowed window sits: -1 left, 0 centre, 1 right. */
    var soloSide: [Int: Int] = [:]
    var settle: DispatchWorkItem?
    /** One queue per app: its windows are set in order, different apps at once, and none holds up Seam. */
    var queues: [pid_t: DispatchQueue] = [:]
    /** Windows with a frame on its way; what they report meanwhile is half done. */
    var moving: [Int: Int] = [:]
    /** A tiled window the user is moving or resizing with the mouse. */
    var dragging: Int?
    var resizing: Int?
    /** The mouse has moved with the button down: a plain click doesn't. */
    var mouseMoved = false
    var drop: (target: Int, zone: Zone)?
    let overlay = Tiler.makeOverlay()
    let border = Tiler.makeBorder()

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        let workspace = NSWorkspace.shared.notificationCenter
        // every app is watched from the start, so its new windows announce themselves
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited { observe(app.pid) }
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.activationPolicy != .prohibited { self.observe(app.pid) }
            self.sync()
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in self.sync() }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            // the switch is done: bring the outline over, the AX rescan can wait a frame
            self.border.orderOut(nil)
            self.border.alphaValue = 0
            // windows on the other Space may have been put back to their own size meanwhile: those are set again
            let shown = windowList(.optionOnScreenOnly)
            for w in shown {
                guard let id = w[kCGWindowNumber as String] as? Int, let rect = self.applied[id], bounds(w) != rect else { continue }
                self.applied[id] = nil
            }
            self.relayout(onScreen: ids(shown))
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; self.border.animator().alphaValue = 1 }
            DispatchQueue.main.async { self.sync() }
        }
        // an app coming to the front may show a window no notification announced (one started through a launcher, like Device Hub)
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

    /**
     * Picks up windows nothing announced, forgets closed ones, and lays everything out. Like yabai, only an
     * app showing a window Seam hasn't met is asked for its windows: each ask is a call into the app, and a
     * busy one (mid Space switch) takes up to a second to answer.
     */
    func sync() {
        let list = windowList(.optionOnScreenOnly)
        var ask = Set<pid_t>()
        for w in list where w[kCGWindowLayer as String] as? Int == 0 {
            // smaller than a tile's minimum either way it's a popup (Finder's Empty Trash), never tiled
            guard let id = w[kCGWindowNumber as String] as? Int, windows[id] == nil, let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let r = bounds(w), r.width >= minPane, r.height >= minPane else { continue }
            ask.insert(pid_t(pid))
        }
        // accessory apps (menu bar apps like Wallpaper) open real windows too; isStandard filters their panels
        for pid in ask where pid != getpid() && NSRunningApplication(processIdentifier: pid)?.activationPolicy != .prohibited {
            for window in AXUIElementCreateApplication(pid).value(kAXWindowsAttribute) as? [AXUIElement] ?? [] { add(window) }
        }
        for (pid, observer) in observers where kill(pid, 0) != 0 && errno == ESRCH {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = nil
        }
        // Accessibility only lists the current Space's windows; one off screen is minimised or on another
        // Space and keeps its place (zero room here), unless the window server has no Space for it: it's gone
        let onScreen = ids(list)
        for id in Set(windows.keys).union(trees.values.flatMap(leaves)) where !onScreen.contains(id) && spaces(of: [id]).isEmpty { forget(id) }
        // a window sent to another desktop (Mission Control) joins that desktop's tree: one call per tree
        // says whether any of its windows is elsewhere, and only then each is asked
        for (key, tree) in trees where Set(spaces(of: leaves(tree))) != [key.space] {
            for id in leaves(tree) {
                let on = spaces(of: [id])
                guard on.count == 1, on[0] != key.space else { continue }
                untile(id)
                let to = TreeKey(space: on[0], display: key.display)
                trees[to] = trees[to].map { appendLeaf($0, id) } ?? .leaf(id)
            }
        }
        relayout(onScreen: onScreen)
    }

    /** Starts watching a window and tiles it, unless it's a dialog, a popup or its app never tiles. */
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

    /** The window's own notifications, each carrying its ID. */
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
            // Only the user's own drag of one window: ours happen with the mouse
            // up, or are the neighbours given way to a live edge resize. A click
            // (switching window) can land mid-relayout, or on an app snapping its
            // size (Terminal's character grid): that's not a resize.
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
            // focus moves on when a window closes, and an app that only hides it (close to the menu bar) sends nothing else
            relayout()
        case kAXWindowCreatedNotification:
            add(element)
            relayout()
            // a new window may not be on screen for a moment yet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.relayout() }
        case kAXUIElementDestroyedNotification:
            guard let id = watched else { return }
            forget(id)
            relayout()
        default:
            // minimised, restored, app hidden or shown: a restored window may not be on screen for a moment yet
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
            // the neighbours follow the edge as it's dragged
            resizeFromEdges(id)
        } else if resizing == nil {
            dragging = id
        }
    }

    /**
     * An app moving its own tile (Zoom grows to the whole screen after login) goes back;
     * only a moved origin counts: an app minimum keeps it and only grows the size.
     * ponytail: an app that always moves itself back would ping-pong; cap retries if one does
     */
    func appMoved(_ id: Int, _ window: AXUIElement) {
        guard id != zoomed, let tile = applied[id], let frame = window.frame else { return showFocus() }
        // grown past a learned maximum (an app that resized late), it never was one: give it its room back
        if let most = maxSizes[id], frame.width > most.width + 2 || frame.height > most.height + 2 {
            maxSizes[id] = nil
            applied[id] = nil
            return relayout()
        }
        // smaller than its tile is the app's own choice (VLC keeps its video's aspect): centre it, don't fight
        if frame.width < tile.width - 2 || frame.height < tile.height - 2 {
            centre(window, frame, in: tile)
        // going native fullscreen moves it too: leave that be
        } else if abs(frame.minX - tile.minX) > 2 || abs(frame.minY - tile.minY) > 2, !window.isFullScreen {
            applied[id] = nil
            return relayout()
        }
        showFocus()
    }

    func treeKey(of id: Int) -> TreeKey? {
        trees.first { path(to: id, in: $0.value) != nil }?.key
    }

    /** Beside `target`, splitting it along its longer side, like i3 on a new window. */
    /**
     * A new window splits the biggest tile on `target`'s display (not the focused one, so
     * widths don't depend on which window happened to be focused: 2 halves, then a 2x2 grid),
     * along its longer side; a column that would come out under `minColumn` stacks instead.
     */
    func tile(_ id: Int, near target: Int?) {
        if let target, target != id, let key = treeKey(of: target), let panes = layouts[key]?.panes,
           let (target, rect) = panes.filter({ $0.key != id }).max(by: { $0.value.width * $0.value.height < $1.value.width * $1.value.height }) {
            let zone: Zone = rect.width >= rect.height && rect.width / 2 >= minColumn ? .right : .bottom
            trees[key] = insertBeside(trees[key]!, target, id, zone)
        } else if let frame = windowFrame(id) {
            var to = shownKey(screen(containing: CGPoint(x: frame.midX, y: frame.midY)), spaces().current)
            if let on = spaces(of: [id]).first { to.space = on }
            trees[to] = trees[to].map { appendLeaf($0, id) } ?? .leaf(id)
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
        if focused == id { focused = nil }
        floatZoomed[id] = nil
        minSizes[id] = nil
        maxSizes[id] = nil
        squeezed.remove(id)
        soloWidth[id] = nil
        soloSide[id] = nil
    }

    /** `onScreen` is the window server's current on-screen list, when the caller just read it. */
    func relayout(onScreen: Set<Int>? = nil) {
        let screens = NSScreen.screens
        let displays = Set(screens.map(key)), (current, all, fullscreen) = spaces()
        // a disconnected display's or deleted desktop's windows move to the main one; sync
        // then sends each to the desktop it's really on
        let main = shownKey(screens[0], current)
        for (gone, tree) in trees where !displays.contains(gone.display) || !all.contains(gone.space) {
            trees[gone] = nil
            for id in leaves(tree) { trees[main] = trees[main].map { appendLeaf($0, id) } ?? .leaf(id) }
        }
        let onScreen = onScreen ?? ids(windowList([.optionOnScreenOnly, .excludeDesktopElements]))
        let visible = { (id: Int) in onScreen.contains(id) }
        layouts = [:]
        var placed: [Int] = []
        for screen in screens {
            let key = shownKey(screen, current)
            // a native fullscreen window's Space is its own: nothing to tile there
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
        // some apps take a moment to resize; reading straight away mistakes that for a minimum
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
    }

    /** Outlines the focused tile: with no gaps, nothing else shows which one it is. */
    func showFocus() {
        guard let id = focused, id != zoomed, let rect = layouts.values.lazy.compactMap({ $0.panes[id] }).first else {
            return border.orderOut(nil)
        }
        // an app with a bigger minimum spills past its tile: outline the window itself, kept on its screen
        let area = tileArea(screen(containing: CGPoint(x: rect.midX, y: rect.midY)))
        let frame = flip(windows[id]?.frame.map { $0.intersection(area) }.flatMap { $0.isEmpty ? nil : $0 } ?? rect)
        // each is a call to the window server, and this runs on every move of every window
        if border.frame != frame { border.setFrame(frame, display: true) }
        if !border.isVisible { border.orderFrontRegardless() }
    }

    /**
     * An app with a minimum size comes out bigger than its tile; remember that
     * minimum and lay out again so its neighbours make room. Minimums only grow
     * here, so this settles.
     */
    func learnMinSizes() {
        var learned = false
        guard moving.isEmpty else { return }
        for id in unsettled where id != dragging && id != resizing && !squeezed.contains(id) {
            guard let window = windows[id], let frame = window.frame, let tile = applied[id] else { continue }
            let known = minSizes[id] ?? .zero
            // bigger than its tile: that's its minimum; smaller than a learned minimum: it never was one
            // (VLC keeps its video's aspect, so a wide tile once made it look 1036 tall at the least)
            func learn(_ got: CGFloat, _ tile: CGFloat, _ known: CGFloat) -> CGFloat {
                got > tile + 2 || got < known - 2 ? got : known
            }
            let size = CGSize(width: learn(frame.width, tile.width, known.width), height: learn(frame.height, tile.height, known.height))
            if abs(size.width - known.width) > 2 || abs(size.height - known.height) > 2 {
                minSizes[id] = size
                learned = true
            }
            // well short of its tile both ways, its app won't let it grow (Device Hub's device view): that's its
            // maximum, and its tile shrinks to it. Short one way is an app keeping its aspect (VLC), which grows
            // with the other side; a few points short is a terminal keeping to its character grid.
            // ponytail: an app still resizing after 0.3s reads as capped; it heals when it grows (`handle`) or on ⌘⌥=
            if frame.width < tile.width - 50, frame.height < tile.height - 50, maxSizes[id] != frame.size {
                maxSizes[id] = frame.size
                learned = true
            }
            centre(window, frame, in: tile)
        }
        unsettled = []
        // the window may have settled bigger than its tile since the outline was drawn
        if learned { relayout() } else { showFocus() }
    }

    /** A window its app keeps smaller than its tile sits in the tile's middle on that axis, not stuck in a corner. */
    func centre(_ window: AXUIElement, _ frame: CGRect, in tile: CGRect) {
        var to = CGPoint(x: frame.width < tile.width - 2 ? tile.midX - frame.width / 2 : tile.minX,
                         y: frame.height < tile.height - 2 ? tile.midY - frame.height / 2 : tile.minY)
        guard abs(to.x - frame.minX) > 2 || abs(to.y - frame.minY) > 2 else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &to)!)
    }

    /** A lone window's tile, narrowed to its `soloWidth` (never under its minimum, never past its maximum) and put at its `soloSide`. */
    func solo(_ id: Int, _ rect: CGRect) -> CGRect {
        let width = min(rect.width, maxSize(id).width, max(rect.width * (soloWidth[id] ?? 1), minSize(id).width)).rounded()
        let x = rect.minX + ((rect.width - width) * CGFloat((soloSide[id] ?? 0) + 1) / 2).rounded()
        return CGRect(x: x, y: rect.minY, width: width, height: rect.height)
    }

    /** Whether it moved the window. One with a maximum goes straight to the middle of its tile, not its corner first. */
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
                self.moving[id]! -= 1
                if self.moving[id] == 0 { self.moving[id] = nil }
                // the size check and the outline wait for the slowest app
                guard self.moving.isEmpty else { return }
                self.scheduleSettle()
                self.showFocus()
            }
        }
        return true
    }

    /** The least room a window gets: what its app allows (unless squeezed), and never under `minPane`. */
    func minSize(_ id: Int) -> CGSize {
        let learned = squeezed.contains(id) ? .zero : minSizes[id] ?? .zero
        return CGSize(width: max(learned.width, minPane), height: max(learned.height, minPane))
    }

    func maxSize(_ id: Int) -> CGSize {
        maxSizes[id] ?? CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
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
