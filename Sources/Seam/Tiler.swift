import AppKit

/** Apps that always float: they're small panels, not workspaces. */
let floatingApps: Set<String> = ["com.apple.systempreferences", "com.apple.calculator"]

let axCallback: AXObserverCallback = { _, element, note, _ in tiler.handle(note as String, element) }

final class Tiler: NSObject {
    /** One tree per Space per display. */
    var trees: [TreeKey: Node] = [:]
    var layouts: [TreeKey: Layout] = [:]
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
    /** Windows resized since the last minimum-size check, and that pending check. */
    var unsettled: Set<Int> = []
    /** Windows made to give up room below their app's minimum by growing a neighbour. */
    var squeezed: Set<Int> = []
    var settle: DispatchWorkItem?
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
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in self.sync() }
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            // the switch is done: bring the outline over, the slow AX rescan can wait a frame
            self.border.orderOut(nil)
            self.border.alphaValue = 0
            // windows on the other Space may have been put back to their own size meanwhile
            self.applied = [:]
            self.relayout()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; self.border.animator().alphaValue = 1 }
            DispatchQueue.main.async { self.sync() }
        }
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in self.showFocus() }
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
        // accessory apps (menu bar apps like Wallpaper) open real windows too; isStandard filters their panels
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited && $0.processIdentifier != getpid() }
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
                // smaller than a tile's minimum either way, it's a popup (Finder's Empty Trash), not a workspace
                if treeKey(of: id) == nil, window.isStandard, let frame = window.frame, frame.width >= minPane, frame.height >= minPane,
                   !floatingApps.contains(app.bundleIdentifier ?? "") { tile(id, near: lastFocus) }
            }
        }
        let live = Set(apps.map(\.processIdentifier))
        for (pid, observer) in observers where !live.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = nil
        }
        // Accessibility only lists the current Space's windows; one still in the
        // window server is on another Space, so it keeps its place (zero room here)
        let existing = windowIDs([.optionAll])
        for id in Set(windows.keys).union(trees.values.flatMap(leaves)) where !seen.contains(id) && !existing.contains(id) { forget(id) }
        // a window sent to another desktop (Mission Control) joins that desktop's tree
        for (key, tree) in trees {
            for id in leaves(tree) {
                let on = spaces(of: id)
                guard on.count == 1, on[0] != key.space else { continue }
                untile(id)
                let to = TreeKey(space: on[0], display: key.display)
                trees[to] = trees[to].map { appendLeaf($0, id) } ?? .leaf(id)
            }
        }
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
            // up, or are the neighbours given way to a live edge resize. A click
            // (switching window) can land mid-relayout, or on an app snapping its
            // size (Terminal's character grid): that's not a resize.
            guard NSEvent.pressedMouseButtons & 1 != 0, mouseMoved, let id = element.windowID, id != zoomed, treeKey(of: id) != nil,
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
            showFocus()
        default:
            sync()
            // a new or restored window may not be on screen for a moment yet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.relayout() }
        }
    }

    func treeKey(of id: Int) -> TreeKey? {
        trees.first { leaves($0.value).contains(id) }?.key
    }

    /** Beside `target`, splitting it along its longer side, like i3 on a new window. */
    func tile(_ id: Int, near target: Int?) {
        if let target, target != id, let key = treeKey(of: target), let rect = layouts[key]?.panes[target] {
            trees[key] = insertBeside(trees[key]!, target, id, rect.width >= rect.height ? .right : .bottom)
        } else if let frame = windows[id]?.frame {
            var to = shownKey(screen(containing: CGPoint(x: frame.midX, y: frame.midY)), spaces().current)
            if let on = spaces(of: id).first { to.space = on }
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
        floatZoomed[id] = nil
        minSizes[id] = nil
        squeezed.remove(id)
    }

    func windowIDs(_ options: CGWindowListOption) -> Set<Int> {
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    func relayout() {
        let screens = NSScreen.screens
        let displays = Set(screens.map(key)), (current, all) = spaces()
        // a disconnected display's or deleted desktop's windows move to the main one; sync
        // then sends each to the desktop it's really on
        let main = shownKey(screens[0], current)
        for (gone, tree) in trees where !displays.contains(gone.display) || !all.contains(gone.space) {
            trees[gone] = nil
            for id in leaves(tree) { trees[main] = trees[main].map { appendLeaf($0, id) } ?? .leaf(id) }
        }
        let onScreen = windowIDs([.optionOnScreenOnly, .excludeDesktopElements])
        // asked once per window: an Accessibility call each, and layout asks many times
        let shown = Set(windows.filter { onScreen.contains($0.key) && !$0.value.isFullScreen }.keys)
        let visible = { (id: Int) in shown.contains(id) }
        layouts = [:]
        var placed: [Int] = []
        for screen in screens {
            let key = shownKey(screen, current)
            guard let tree = trees[key] else { continue }
            let area = tileArea(screen)
            var out = Layout()
            layout(tree, in: area, visible: visible, minSize: minSize, into: &out)
            layouts[key] = out
            for (id, rect) in out.panes where place(id, id == zoomed ? area : rect) && id != zoomed { placed.append(id) }
        }
        unsettled.formUnion(placed)
        settle?.cancel()
        let check = DispatchWorkItem { self.learnMinSizes() }
        settle = check
        // some apps take a moment to resize; reading straight away mistakes that for a minimum
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
        showFocus()
    }

    /** Outlines the focused tile: with no gaps, nothing else shows which one it is. */
    func showFocus() {
        guard let id = focusedID(), id != zoomed, let rect = layouts.values.lazy.compactMap({ $0.panes[id] }).first else {
            return border.orderOut(nil)
        }
        // an app with a bigger minimum spills past its tile: outline the window itself, kept on its screen
        let area = tileArea(screen(containing: CGPoint(x: rect.midX, y: rect.midY)))
        let frame = windows[id]?.frame.map { $0.intersection(area) }.flatMap { $0.isEmpty ? nil : $0 } ?? rect
        border.setFrame(flip(frame), display: true)
        border.orderFrontRegardless()
    }

    /**
     * An app with a minimum size comes out bigger than its tile; remember that
     * minimum and lay out again so its neighbours make room. Minimums only grow
     * here, so this settles.
     */
    func learnMinSizes() {
        var learned = false
        for id in unsettled where id != dragging && id != resizing && !squeezed.contains(id) {
            guard let frame = windows[id]?.frame, let tile = applied[id] else { continue }
            let known = minSizes[id] ?? .zero
            let size = CGSize(width: frame.width > tile.width + 2 ? frame.width : known.width,
                              height: frame.height > tile.height + 2 ? frame.height : known.height)
            if size.width > known.width + 2 || size.height > known.height + 2 {
                minSizes[id] = size
                learned = true
            }
        }
        unsettled = []
        // the window may have settled bigger than its tile since the outline was drawn
        if learned { relayout() } else { showFocus() }
    }

    /** Whether it moved the window. */
    @discardableResult
    func place(_ id: Int, _ rect: CGRect) -> Bool {
        guard id != dragging, id != resizing, applied[id] != rect else { return false }
        windows[id]?.setFrame(rect)
        applied[id] = rect
        return true
    }

    /** The least room a window gets: what its app allows (unless squeezed), and never under `minPane`. */
    func minSize(_ id: Int) -> CGSize {
        let learned = squeezed.contains(id) ? .zero : minSizes[id] ?? .zero
        return CGSize(width: max(learned.width, minPane), height: max(learned.height, minPane))
    }

    @objc func retile() {
        trees = [:]
        windows = [:]
        applied = [:]
        minSizes = [:]
        squeezed = []
        zoomed = nil
        sync()
    }
}
