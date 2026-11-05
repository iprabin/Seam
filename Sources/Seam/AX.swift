import AppKit

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
        guard let p = value(kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
    func setPosition(_ point: CGPoint) {
        var origin = point
        guard let p = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, p)
    }
    func setFrame(_ rect: CGRect) {
        var size = rect.size
        guard let s = AXValueCreate(.cgSize, &size) else { return }
        // size, position, size again: either order alone gets clamped by the display the window is on
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, s)
        setPosition(rect.origin)
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, s)
    }
    /** What yabai manages, resizable too: a standard window on the normal level, on one Space. Not a dialog, sheet, panel, popover or always-on-top window (Firefox PiP). */
    var isStandard: Bool {
        func settable(_ attribute: String) -> Bool {
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(self, attribute as CFString, &settable)
            return settable.boolValue
        }
        guard settable(kAXSizeAttribute), settable(kAXPositionAttribute), value(kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              let id = windowID else { return false }
        var level: Int32 = 0
        CGSGetWindowLevel(CGSMainConnectionID(), CGWindowID(id), &level)
        return level == CGWindowLevelForKey(.normalWindow) && spaces(of: [id]).count <= 1
    }
    var isFullScreen: Bool { value("AXFullScreen") as? Bool == true }
}

extension NSRunningApplication {
    /** `processIdentifier` is -1 for an app started through a launcher (Device Hub); then it's found as its windows' owner. */
    var pid: pid_t {
        guard processIdentifier <= 0, let path = executableURL?.path else { return processIdentifier }
        for owner in Set(windowList(.optionAll).compactMap { $0[kCGWindowOwnerPID as String] as? Int }) {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid_t(owner), &buf, UInt32(buf.count)) > 0, String(cString: buf) == path { return pid_t(owner) }
        }
        return processIdentifier
    }
}

func bundle(_ pid: pid_t) -> String {
    (NSRunningApplication(processIdentifier: pid) ?? NSWorkspace.shared.runningApplications.first { $0.pid == pid })?.bundleIdentifier ?? ""
}

/** From the window server, so it never blocks on the app; mid-animation it's the animated frame, so rough checks only. Use `frame` for anything learned or drawn. */
func windowFrame(_ id: Int) -> CGRect? {
    windowList(.optionIncludingWindow, id).first.flatMap(bounds)
}

func windowList(_ options: CGWindowListOption, _ window: Int = Int(kCGNullWindowID)) -> [[String: Any]] {
    CGWindowListCopyWindowInfo(options, CGWindowID(window)) as? [[String: Any]] ?? []
}
func ids(_ list: [[String: Any]]) -> Set<Int> { Set(list.compactMap { $0[kCGWindowNumber as String] as? Int }) }
func bounds(_ info: [String: Any]) -> CGRect? {
    (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
}

/** AppKit (bottom-left origin) ⇄ Accessibility (top-left); its own inverse. */
func flip(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: NSScreen.screens[0].frame.height - r.maxY, width: r.width, height: r.height)
}
func mouseAX() -> CGPoint {
    let m = NSEvent.mouseLocation
    return CGPoint(x: m.x, y: NSScreen.screens[0].frame.height - m.y)
}
func screen(containing point: CGPoint) -> NSScreen {
    NSScreen.screens.first { flip($0.frame).contains(point) } ?? NSScreen.screens[0]
}
/** Just past a corner of its display, the one overlapping other displays least: over another display a window shows, and joins that display's Space. macOS keeps a window from leaving entirely, so a pixel may show. */
func parkingSpot(_ display: CGRect, others: [CGRect], size: CGSize) -> CGPoint {
    let right = display.maxX - 1, left = display.minX + 1 - size.width, bottom = display.maxY - 1, top = display.minY + 1 - size.height
    let spots = [CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom), CGPoint(x: right, y: top), CGPoint(x: left, y: top)]
    func overlap(_ spot: CGPoint) -> CGFloat {
        others.reduce(0) { sum, other in
            let shared = other.intersection(CGRect(origin: spot, size: size))
            return sum + (shared.isNull ? 0 : shared.width * shared.height)
        }
    }
    return spots.min { overlap($0) < overlap($1) } ?? spots[0]
}
func tileArea(_ screen: NSScreen) -> CGRect { flip(screen.visibleFrame).insetBy(dx: gap, dy: gap) }

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension CGSize {
    static let unbounded = CGSize(width: CGFloat.infinity, height: .infinity)
}

// private Spaces API, the same calls yabai and Amethyst use
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetWindowLevel") @discardableResult func CGSGetWindowLevel(_ cid: Int32, _ window: CGWindowID, _ level: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

/** One tree per workspace per Space per display. */
struct TreeKey: Hashable {
    var space: UInt64
    var display: CGDirectDisplayID
    var workspace = 1
}

/** Each display's current Space ("Main" when displays share Spaces), every Space, and the native fullscreen ones. */
func spaces() -> (current: [String: UInt64], all: Set<UInt64>, fullscreen: Set<UInt64>) {
    let list = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] ?? []
    var current: [String: UInt64] = [:], all = Set<UInt64>(), fullscreen = Set<UInt64>()
    for display in list {
        let id = display["Display Identifier"] as? String ?? "Main"
        current[id] = ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
        for space in display["Spaces"] as? [[String: Any]] ?? [] {
            guard let s = (space["id64"] as? NSNumber)?.uint64Value else { continue }
            all.insert(s)
            if space["type"] as? Int == 4 { fullscreen.insert(s) } // 4: an app's own fullscreen Space
        }
    }
    return (current, all, fullscreen)
}

func shownKey(_ screen: NSScreen, _ current: [String: UInt64]) -> TreeKey {
    let display = screen.displayID
    let uuid = CGDisplayCreateUUIDFromDisplayID(display).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    return TreeKey(space: uuid.flatMap { current[$0] } ?? current["Main"] ?? 0, display: display)
}

/** The Spaces the windows are on: several for one on all desktops, none for a closed one. */
func spaces(of windows: [Int]) -> [UInt64] {
    let allSpaces: Int32 = 7 // current, other and fullscreen Spaces alike
    let list = CGSCopySpacesForWindows(CGSMainConnectionID(), allSpaces, windows as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []
    return list.map(\.uint64Value)
}
