#if E2E
import AppKit

// Compiled only into e2e/run.sh's test build: real key presses and drags, and a state dump, driven by e2e/driver.swift.

/** Only these apps' windows are managed, so a test run leaves the user's alone. */
var e2eOnly: Set<pid_t> = []
var e2ePath = ""

func e2eStart() {
    DistributedNotificationCenter.default().addObserver(forName: Notification.Name("seam.e2e"), object: nil, queue: .main, using: { note in
        guard let line = note.object as? String else { return }
        let words = line.split(separator: " ").map(String.init)
        let done = { e2eDump(words[0]) }
        switch words[1] {
        case "only":
            e2ePath = words[2]
            e2eOnly = Set(words[3...].compactMap { pid_t($0) })
            tiler.sync()
            done()
        case "key":
            e2eKey(CGKeyCode(words[2]) ?? 0, words.count > 3 ? words[3] : "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: done)
        case "mouse":
            e2eMouse(.mouseMoved, CGPoint(x: Double(words[2]) ?? 0, y: Double(words[3]) ?? 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: done)
        case "drag":
            let n = words[2...5].map { Double($0) ?? 0 }
            e2eDrag(CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3]), done)
        case "retile":
            tiler.retile()
            done()
        case "sync":
            tiler.sync()
            done()
        default: done()
        }
    })
}

func e2eKey(_ code: CGKeyCode, _ mods: String) {
    var flags = CGEventFlags()
    for (letter, flag) in [("c", CGEventFlags.maskCommand), ("o", .maskAlternate), ("s", .maskShift), ("t", .maskControl)] where mods.contains(letter) { flags.insert(flag) }
    if (123...126).contains(code) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) } // as a real arrow key sends them
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

func e2eMouse(_ type: CGEventType, _ point: CGPoint) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.flags = [] // a synthetic key's modifiers stick to the next event; a control-press doesn't drag a window
    event?.post(tap: .cghidEventTap)
}

func e2eDrag(_ from: CGPoint, _ to: CGPoint, _ done: @escaping () -> Void) {
    e2eMouse(.mouseMoved, from)
    let steps = 30, start = DispatchTime.now() + 0.1
    DispatchQueue.main.asyncAfter(deadline: start) { e2eMouse(.leftMouseDown, from) }
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps), at = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        DispatchQueue.main.asyncAfter(deadline: start + 0.1 + 0.02 * Double(i)) { e2eMouse(.leftMouseDragged, at) }
    }
    DispatchQueue.main.asyncAfter(deadline: start + 0.1 + 0.02 * Double(steps) + 0.35) {
        e2eMouse(.leftMouseUp, to)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
    }
}

func e2eDump(_ id: String) {
    let current = spaces().current
    let trees = tiler.trees.map { key, tree -> [String: Any] in
        ["display": Int(key.display), "space": Int(key.space), "workspace": key.workspace, "windows": leaves(tree)]
    }
    let screens = NSScreen.screens.map { screen -> [String: Any] in
        let area = tileArea(screen), frame = flip(screen.frame), key = tiler.shown(shownKey(screen, current))
        return ["display": Int(key.display), "space": Int(key.space), "workspace": key.workspace,
                "area": [area.minX, area.minY, area.width, area.height], "frame": [frame.minX, frame.minY, frame.width, frame.height]]
    }
    let state: [String: Any] = ["id": id, "trees": trees, "screens": screens, "parked": Array(tiler.parked), "focused": tiler.focused ?? 0, "known": Array(tiler.windows.keys)]
    guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
    try? data.write(to: URL(fileURLWithPath: e2ePath + ".tmp"))
    rename(e2ePath + ".tmp", e2ePath)
}
#endif
