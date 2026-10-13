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
