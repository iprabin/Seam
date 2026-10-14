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

// Spaces aren't public API; these window-server calls are what yabai and Amethyst use.
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

/** A tree per Space per display: each desktop keeps its own layout. */
struct TreeKey: Hashable, Codable {
    var space: UInt64
    var display: CGDirectDisplayID
}

/** Each display's current Space ("Main" when displays share Spaces), and every Space that exists. */
func spaces() -> (current: [String: UInt64], all: Set<UInt64>) {
    let list = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] ?? []
    var current: [String: UInt64] = [:], all = Set<UInt64>()
    for display in list {
        let id = display["Display Identifier"] as? String ?? "Main"
        current[id] = ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
        for space in display["Spaces"] as? [[String: Any]] ?? [] {
            if let s = (space["id64"] as? NSNumber)?.uint64Value { all.insert(s) }
        }
    }
    return (current, all)
}

/** The tree shown on `screen` right now. */
func shownKey(_ screen: NSScreen, _ current: [String: UInt64]) -> TreeKey {
    let display = key(screen)
    let uuid = CGDisplayCreateUUIDFromDisplayID(display).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    return TreeKey(space: uuid.flatMap { current[$0] } ?? current["Main"] ?? 0, display: display)
}

/** The Spaces a window is on: several for one shown on all desktops. */
func spaces(of window: Int) -> [UInt64] {
    let list = CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [window] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []
    return list.map(\.uint64Value)
}
