import AppKit

/** Apps that always float: they're small panels, not workspaces. */
let floatingApps: Set<String> = ["com.apple.systempreferences", "com.apple.calculator"]

let axCallback: AXObserverCallback = { _, element, note, _ in tiler.handle(note as String, element) }

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
    /** Windows resized since the last minimum-size check, and that pending check. */
    var unsettled: Set<Int> = []
    /** Windows made to give up room below their app's minimum by growing a neighbour. */
    var squeezed: Set<Int> = []
    var settle: DispatchWorkItem?
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
        squeezed.remove(id)
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
