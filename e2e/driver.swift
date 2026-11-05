import AppKit

// Drives the E2E build of Seam. Every wait polls, so a pass is the state really reached and a fail is the state it never reached.
let dir = CommandLine.arguments[1], filter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let statePath = dir + "/state.json"
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// MARK: helper app: a second process with its own windows

if CommandLine.arguments.contains("--helper") {
    let n = Int(CommandLine.arguments.last ?? "1") ?? 1
    var held: [NSWindow] = []
    for i in 1...n {
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 400), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "helper\(i)"; w.isReleasedWhenClosed = false; held.append(w); w.makeKeyAndOrderFront(nil)
        print(w.windowNumber)
    }
    fflush(stdout)
    func front() { NSRunningApplication.current.activate(options: [.activateAllWindows]); app.activate(ignoringOtherApps: true) }
    signal(SIGUSR1, SIG_IGN)
    let usr = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    usr.setEventHandler(handler: front); usr.resume()
    // a background app shuffling its own focus for two seconds
    signal(SIGUSR2, SIG_IGN)
    let flip = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
    flip.setEventHandler {
        for i in 0..<100 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(i)) { held[i % held.count].makeKeyAndOrderFront(nil) } }
    }
    flip.resume()
    DispatchQueue.main.async(execute: front)
    app.run()
}

// MARK: Seam

struct Tree { let display: Int, space: Int, workspace: Int, windows: [Int] }
struct Screen { let display: Int, space: Int, workspace: Int, area: CGRect, frame: CGRect }
struct State { var trees: [Tree] = [], screens: [Screen] = [], parked = Set<Int>(), focused = 0, known = Set<Int>()
    func tree(of id: Int) -> Tree? { trees.first { $0.windows.contains(id) } }
    func workspace(of id: Int) -> Int? { tree(of: id)?.workspace }
    var tiled: [Int] { trees.flatMap(\.windows) }
}
var seq = 0, pids: [Int32] = [getpid()]
func rect(_ a: Any?) -> CGRect { let n = a as? [Double] ?? [0, 0, 0, 0]; return CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }

/** Sends a command, waits for Seam to finish it, and returns the state; a Seam that never answers is dead. */
@discardableResult func seam(_ command: String) -> State {
    seq += 1
    let id = String(seq)
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("seam.e2e"), object: "\(id) \(command)", userInfo: nil, deliverImmediately: true)
    let end = Date().addingTimeInterval(8)
    while Date() < end {
        if let d = FileManager.default.contents(atPath: statePath), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], j["id"] as? String == id {
            var s = State()
            s.trees = (j["trees"] as? [[String: Any]] ?? []).map { Tree(display: $0["display"] as? Int ?? 0, space: $0["space"] as? Int ?? 0, workspace: $0["workspace"] as? Int ?? 0, windows: $0["windows"] as? [Int] ?? []) }
            s.screens = (j["screens"] as? [[String: Any]] ?? []).map { Screen(display: $0["display"] as? Int ?? 0, space: $0["space"] as? Int ?? 0, workspace: $0["workspace"] as? Int ?? 0, area: rect($0["area"]), frame: rect($0["frame"])) }
            s.parked = Set(j["parked"] as? [Int] ?? []); s.focused = j["focused"] as? Int ?? 0; s.known = Set(j["known"] as? [Int] ?? [])
            return s
        }
        usleep(20_000)
    }
    print("  !! Seam did not answer: \(command)")
    return State()
}
var state: State { seam("state") }
func manage() { seam("only \(statePath) \(pids.map(String.init).joined(separator: " "))") }
func key(_ code: Int, _ mods: String = "co") { seam("key \(code) \(mods)") }
let digit = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25]
func goTo(_ n: Int) { key(digit[n] ?? 0) }
func send(_ n: Int) { key(digit[n] ?? 0, "cos") }
let left = 123, right = 124, down = 125, up = 126
func mouse(_ p: CGPoint) { seam("mouse \(p.x) \(p.y)") }

// MARK: windows

/** Never freed: AppKit still touches a closed window for a while, and this process frees from a background thread. */
var everyWindow: [NSWindow] = []
final class W { let win: NSWindow, id: Int
    init(_ win: NSWindow) { self.win = win; id = win.windowNumber; everyWindow.append(win) }
    var frame: CGRect { (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]])?.first.flatMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } } ?? .zero }
    var titleBar: CGPoint { CGPoint(x: frame.midX, y: frame.minY + 12) }
}
var open: [W] = []
func onMain<T>(_ f: @escaping () -> T) -> T { DispatchQueue.main.sync(execute: f) }
func activate() { onMain { NSRunningApplication.current.activate(options: [.activateAllWindows]); app.activate(ignoringOtherApps: true) } }
@discardableResult func window(level: NSWindow.Level = .normal, behavior: NSWindow.CollectionBehavior = [], style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable], panel: Bool = false, on: CGRect? = nil) -> W {
    let w: W = onMain {
        let cls: NSWindow.Type = panel ? NSPanel.self : NSWindow.self
        let height = NSScreen.screens[0].frame.height
        let spot = on.map { NSRect(x: $0.midX - 210, y: height - $0.midY - 150, width: 420, height: 300) } ?? NSRect(x: 300, y: 300, width: 420, height: 300)
        let n = cls.init(contentRect: spot, styleMask: style, backing: .buffered, defer: false)
        n.isReleasedWhenClosed = false; n.level = level; n.collectionBehavior = behavior
        n.setFrame(spot, display: false) // init constrains it to the main display
        if !style.contains(.fullSizeContentView) { n.collectionBehavior.insert(.fullScreenPrimary) }
        NSRunningApplication.current.activate(options: [.activateAllWindows]); app.activate(ignoringOtherApps: true)
        n.makeKeyAndOrderFront(nil)
        return W(n)
    }
    open.append(w)
    usleep(450_000)
    return w
}
func windows(_ n: Int) -> [W] { (0..<n).map { _ in window() } }
func close(_ w: W) { onMain { w.win.close() }; open.removeAll { $0 === w }; usleep(250_000) }
func focus(_ w: W) { onMain { NSRunningApplication.current.activate(options: [.activateAllWindows]); app.activate(ignoringOtherApps: true); w.win.makeKeyAndOrderFront(nil) }; usleep(300_000) }

// MARK: checks

var passed = 0, failed: [String] = [], scenario = ""
func until(_ seconds: Double = 3, _ test: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    repeat { if test() { return true }; usleep(100_000) } while Date() < end
    return false
}
func check(_ name: String, _ detail: @autoclosure () -> String = "", _ test: () -> Bool) {
    if until(3, test) { passed += 1; print("  ok   \(name)") } else { failed.append("\(scenario): \(name)"); print("  FAIL \(name) \(detail())") }
    fflush(stdout)
}
func near(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4 && abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4 }
func part(_ a: CGRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: a.minX + a.width * x, y: a.minY + a.height * y, width: a.width * w, height: a.height * h) }
func checkFrame(_ name: String, _ w: W, _ r: @autoclosure () -> CGRect) { check(name, "got \(w.frame) want \(r())") { near(w.frame, r()) } }
func onScreenFully(_ w: W, _ s: State) -> Bool { s.screens.contains { $0.frame.insetBy(dx: -2, dy: -2).contains(w.frame) } }
func checkHidden(_ name: String, _ w: W) { check(name, "got \(w.frame) parked \(state.parked.contains(w.id)) showing \(state.screens.map(\.workspace)) its ws \(state.workspace(of: w.id) ?? -1)") { let s = state; return s.parked.contains(w.id) && !onScreenFully(w, s) } }
func checkShowing(_ name: String, _ w: W) { check(name, "got \(w.frame) ws \(state.workspace(of: w.id) ?? -1)") { let s = state; return !s.parked.contains(w.id) && onScreenFully(w, s) } }
func checkWorkspace(_ name: String, _ n: Int, _ screen: Int = 0) { check(name, "showing \(state.screens.map(\.workspace)) driver front \(frontmost() == getpid()) front \(onMain { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }) focused \(state.focused) open \(open.map(\.id))") { let s = state; return s.screens.count > screen && s.screens[screen].workspace == n } }
/** Nothing lost, whatever happened: every open window is on a display or parked, and no tree holds more than four. */
func checkInvariants() {
    check("invariant: no tree over 4 tiles", "\(state.trees)") { state.trees.allSatisfy { $0.windows.count <= 4 } }
    check("invariant: every tiled window showing or parked", "\(open.map { "\($0.id) \($0.frame) \(state.parked.contains($0.id) ? "parked" : "") ws\(state.workspace(of: $0.id) ?? -1)" }) screens \(state.screens.map(\.frame)) trees \(state.trees.map { "\($0.display)/\($0.space)/\($0.workspace):\($0.windows)" })") {
        let s = state
        return s.tiled.allSatisfy { id in s.parked.contains(id) || open.first { $0.id == id }.map { onScreenFully($0, s) } ?? true }
    }
    check("invariant: no window in two trees") { let t = state.tiled; return Set(t).count == t.count }
}

// MARK: displays and the second app

var display: Process?
func plug(_ side: String, _ size: (Int, Int) = (1920, 1080)) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: dir + "/vdisplay")
    p.arguments = [side, String(size.0), String(size.1)]; p.standardOutput = Pipe()
    try? p.run(); display = p
    _ = until(8) { state.screens.count == 2 }
    usleep(1_500_000)
}
func unplug() {
    display?.terminate(); display?.waitUntilExit(); display = nil
    _ = until(8) { state.screens.count == 1 }
    usleep(1_500_000)
}
var helper: Process?
func startHelper(_ n: Int) -> [Int] {
    let p = Process(), out = Pipe(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = [dir, "", "--helper", String(n)]; p.standardOutput = out
    try? p.run(); helper = p
    pids = [getpid(), p.processIdentifier]; manage()
    var text = ""
    _ = until(5) { text += String(data: out.fileHandleForReading.availableData, encoding: .utf8) ?? ""; return text.split(separator: "\n").count >= n }
    usleep(800_000)
    return text.split(separator: "\n").compactMap { Int($0) }
}
/** As ⌘Tab: the helper comes forward itself, since macOS won't let this process hand it the focus. */
func frontHelper() { if let p = helper { kill(p.processIdentifier, SIGUSR1) }; usleep(500_000) }
func frontmost() -> Int32 { onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 } }
func stopHelper() { helper?.terminate(); helper?.waitUntilExit(); helper = nil; pids = [getpid()]; manage() }

func reset() {
    if helper != nil { stopHelper() }
    for w in open { onMain { w.win.close() } }
    open = []
    if display != nil { unplug() }
    _ = until(4) { seam("sync").trees.isEmpty }
    if !state.trees.isEmpty { seam("retile"); usleep(500_000) }
    mouse(state.screens.first.map { $0.area.center } ?? .zero)
    activate()
}
extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }
var main: CGRect { state.screens[0].area }
func other(_ s: State) -> Screen { s.screens[1] }

// MARK: scenarios

let scenarios: [(String, () -> Void)] = [
("layout: 1, 2, 3, 4 windows", {
    let a = main, w = windows(4)
    checkFrame("first of four, top left", w[0], part(a, 0, 0, 0.5, 0.5))
    checkFrame("right column top", w[1], part(a, 0.5, 0, 0.5, 0.5))
    checkFrame("right column bottom", w[2], part(a, 0.5, 0.5, 0.5, 0.5))
    checkFrame("fourth under the first", w[3], part(a, 0, 0.5, 0.5, 0.5))
    close(w[3]); checkFrame("closing one gives its room back", w[0], part(a, 0, 0, 0.5, 1))
    let again = window(); check("a window after a close stays here") { state.workspace(of: again.id) == 1 }
}),
("workspaces: overflow, switching, dead numbers", {
    let w = windows(5)
    checkWorkspace("fifth window jumps to workspace 2", 2)
    checkFrame("fifth fills its workspace", w[4], main)
    for i in 0..<4 { checkHidden("window \(i + 1) parked", w[i]) }
    goTo(1); checkWorkspace("⌘⌥1 goes back", 1); checkHidden("fifth parked", w[4]); checkShowing("first back", w[0])
    checkFrame("grid intact after the trip", w[0], part(main, 0, 0, 0.5, 0.5))
    goTo(2); checkWorkspace("⌘⌥2 goes forward", 2)
    goTo(7); checkWorkspace("⌘⌥7 on an empty number does nothing", 2)
    goTo(2); checkWorkspace("⌘⌥ the current number does nothing", 2)
    let more = windows(4); check("ninth window opens workspace 3") { state.workspace(of: more[3].id) == 3 }
    checkInvariants()
}),
("workspaces die when empty", {
    let w = windows(5)
    close(w[4]); checkWorkspace("closing the last window returns to 1", 1); checkShowing("grid back", w[0])
    let x = windows(1)[0]; check("the freed number is reused") { state.workspace(of: x.id) == 2 }
    goTo(1); close(x); check("a hidden workspace dies when its window closes") { state.trees.count == 1 }
    goTo(2); checkWorkspace("and its number no longer answers", 1)
    let a = windows(1)[0], b = windows(4); _ = a
    check("gap setup: 3 workspaces or fewer") { state.trees.count <= 3 }
    close(b.last!); checkInvariants()
}),
("send windows between workspaces", {
    let w = windows(5)
    goTo(1); focus(w[0]); send(2)
    check("⌘⌥⇧2 moves it") { state.workspace(of: w[0].id) == 2 }
    checkHidden("and it leaves", w[0]); checkWorkspace("you stay", 1)
    focus(w[1]); send(1); check("sending to the current one does nothing") { state.workspace(of: w[1].id) == 1 }
    focus(w[1]); send(5); check("sending to an empty number makes it") { state.workspace(of: w[1].id) == 5 }
    goTo(2); focus(w[4]); send(5); focus(w[0]); send(5)
    checkWorkspace("sending the last one away leaves the dead workspace", state.workspace(of: w[2].id) ?? 1)
    checkInvariants()
}),
("send to a full workspace overflows", {
    let w = windows(5)
    focus(w[4]); send(1)
    check("over the limit it goes on to the next with room") { (state.trees.first { $0.windows.contains(w[4].id) }?.workspace ?? 0) >= 2 }
    checkInvariants()
}),
("rapid switching, one app on both workspaces", {
    let w = windows(5)
    for round in 1...12 {
        goTo(1); checkWorkspace("round \(round): 1 holds", 1)
        usleep(700_000); checkWorkspace("round \(round): 1 still holds after focus settles", 1)
        goTo(2); checkWorkspace("round \(round): 2 holds", 2)
        usleep(700_000); checkWorkspace("round \(round): 2 still holds after focus settles", 2)
    }
    for _ in 1...10 { goTo(1); goTo(2) }
    usleep(1_000_000); checkWorkspace("mashing the keys lands on the last one", 2)
    checkHidden("and the other is hidden", w[0]); checkShowing("and this one shown", w[4]); checkInvariants()
}),
("a background app's focus can't swallow the jump", {
    for round in 1...4 {
        let w = windows(2), h = startHelper(2); _ = h
        activate(); usleep(500_000)
        check("round \(round): setup, four tiles") { state.trees.first?.windows.count == 4 }
        kill(helper!.processIdentifier, SIGUSR2); usleep(100_000)
        let fifth = window()
        checkWorkspace("round \(round): fifth still jumps", 2); checkShowing("round \(round): and shows", fifth)
        _ = w; reset()
    }
}),
("focus jumps to a hidden workspace", {
    let w = windows(5)
    goTo(1); focus(w[4]); checkWorkspace("focusing a parked window shows its workspace", 2); checkShowing("it's on screen", w[4])
    goTo(1); checkWorkspace("and back", 1)
}),
("two apps", {
    let w = windows(4), h = startHelper(1)
    check("helper's window opens workspace 2 and jumps") { state.workspace(of: h[0]) == 2 }
    checkWorkspace("showing 2", 2)
    goTo(1); checkWorkspace("back on 1", 1)
    frontHelper(); checkWorkspace("⌘Tab to the helper jumps", 2)
    focus(w[0]); checkWorkspace("⌘Tab back jumps back", 1)
    goTo(2); check("⌘⌥2 gives the keyboard to that workspace's app", "front \(frontmost())") { frontmost() == helper!.processIdentifier }
    goTo(1); check("⌘⌥1 gives it back", "front \(frontmost())") { frontmost() == getpid() }
    stopHelper(); check("an app quitting with parked windows clears them") { state.trees.count == 1 && !state.known.contains(h[0]) }
}),
("background window does not jump", {
    let w = windows(4), h = startHelper(1); goTo(1); focus(w[0])
    onMain { let n = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false); n.isReleasedWhenClosed = false; n.orderBack(nil); open.append(W(n)) }
    usleep(800_000); checkWorkspace("stays put for a window behind", 1); _ = h
}),
("windows Seam must leave alone", {
    let base = window(), a = main
    let before = CGRect(x: 300, y: 0, width: 420, height: 300).width
    let pip = window(level: .floating), sticky = window(behavior: [.canJoinAllSpaces]), panel = window(style: [.titled, .utilityWindow, .resizable], panel: true), fixed = window(style: [.titled, .closable])
    for (name, w) in [("always-on-top", pip), ("all desktops", sticky), ("panel", panel), ("fixed size", fixed)] {
        check("\(name) not tiled") { state.tree(of: w.id) == nil }
        check("\(name) not resized", "\(w.frame)") { abs(w.frame.width - before) < 2 }
    }
    checkFrame("the tile keeps the screen", base, a)
    let more = windows(3); check("floats don't count toward four") { state.workspace(of: more[2].id) == 1 }
    let fifth = window(); checkWorkspace("the real fifth still overflows", 2); _ = fifth
    check("float stays visible on the other workspace") { onScreenFully(pip, state) }
}),
("window turns always-on-top after tiling", {
    let w = windows(2), a = main
    onMain { w[1].win.level = .floating }
    seam("sync"); check("Seam lets it go") { seam("sync").tree(of: w[1].id) == nil }
    checkFrame("its neighbour takes the room", w[0], a)
    onMain { w[0].win.collectionBehavior = [.canJoinAllSpaces] }
    check("same for one set to all desktops") { seam("sync").tree(of: w[0].id) == nil }
}),
("float and zoom", {
    let w = windows(4), a = main
    focus(w[0]); key(8); check("⌘⌥C floats") { state.tree(of: w[0].id) == nil }
    let extra = window(); check("its slot is free") { state.workspace(of: extra.id) == 1 }
    focus(w[0]); key(8); check("⌘⌥C on a full workspace overflows, not five tiles") { state.workspace(of: w[0].id) == 2 }
    goTo(1); focus(w[1]); key(36); checkFrame("⌘⌥Return zooms", w[1], a)
    goTo(2); checkWorkspace("switch away while zoomed", 2); checkHidden("zoomed window parks", w[1])
    goTo(1); checkFrame("zoom survives the trip", w[1], a)
    focus(w[1]); key(36); checkFrame("unzoom", w[1], part(a, 0.5, 0, 0.5, 0.5))
    checkInvariants()
}),
("minimise", {
    let w = windows(5)
    goTo(1); onMain { w[0].win.miniaturize(nil) }; usleep(900_000)
    goTo(2); goTo(1); checkWorkspace("trip with a minimised window", 1)
    onMain { w[0].win.deminiaturize(nil) }; usleep(900_000)
    checkShowing("restored into its tile", w[0])
    onMain { w[1].win.miniaturize(nil) }; usleep(900_000); goTo(2); checkWorkspace("away with one minimised", 2)
    onMain { w[1].win.deminiaturize(nil) }; usleep(900_000)
    checkWorkspace("restoring it focuses it, so its workspace shows", 1); checkShowing("restored into its tile", w[1])
    goTo(2)
    onMain { w[4].win.miniaturize(nil) }; usleep(900_000)
    checkInvariants()
}),
("hidden app", {
    let w = windows(3), h = startHelper(2); _ = h
    let app2 = NSRunningApplication(processIdentifier: helper!.processIdentifier)
    app2?.hide(); usleep(800_000); goTo(1); focus(w[0])
    app2?.unhide(); usleep(800_000); checkInvariants()
}),
("resize and drag on the same display", {
    let w = windows(2), a = main
    seam("drag \(w[0].titleBar.x) \(w[0].titleBar.y) \(w[0].titleBar.x + 40) \(w[0].titleBar.y + 60)")
    checkFrame("a short drag snaps back", w[0], part(a, 0, 0, 0.5, 1))
    let t = w[0].titleBar, r = w[1].frame
    seam("drag \(t.x) \(t.y) \(r.midX) \(r.midY)"); checkFrame("drop in the middle swaps", w[0], part(a, 0.5, 0, 0.5, 1))
    goTo(1); checkInvariants()
}),
("retile with parked windows", {
    let w = windows(6); seam("retile"); usleep(900_000)
    checkInvariants(); check("all still tracked") { w.allSatisfy { state.tree(of: $0.id) != nil } }
}),
("native fullscreen", {
    let w = windows(5)
    goTo(1); focus(w[0]); onMain { w[0].win.toggleFullScreen(nil) }; usleep(2_500_000)
    seam("sync"); onMain { w[0].win.toggleFullScreen(nil) }; usleep(2_500_000); seam("sync")
    checkShowing("comes back to a tile", w[0]); checkInvariants()
}),
("macOS desktops keep their own workspaces", {
    let w = windows(5); goTo(1); let home = state.screens[0].space
    key(right, "t"); usleep(1_500_000)
    if state.screens[0].space == home { key(left, "t"); usleep(1_500_000) }
    check("the Desktop changed") { state.screens[0].space != home }
    let there = startHelper(1)
    check("a new window there starts that Desktop's own tree", "\(state.trees)") { let t = state.tree(of: there.first ?? 0); return t?.workspace == 1 && t?.space != home }
    checkWorkspace("workspace 1 there", 1)
    stopHelper(); usleep(500_000)
    activate(); usleep(1_500_000)
    check("back on the first Desktop") { state.screens[0].space == home }
    checkWorkspace("its workspace kept", 1); checkShowing("grid intact", w[0]); checkHidden("parked stayed parked", w[4])
}),
("display right: drag to the empty display", {
    let w = windows(2); plug("right"); let s = state, ext = other(s)
    let t = w[1].titleBar
    seam("drag \(t.x) \(t.y) \(ext.area.midX) \(ext.area.midY)")
    checkFrame("it fills the display", w[1], other(state).area)
    check("in that display's tree") { state.tree(of: w[1].id)?.display == ext.display }
    checkFrame("the other refills", w[0], main)
    seam("sync"); usleep(600_000); check("sync leaves it there") { seam("sync").tree(of: w[1].id)?.display == ext.display }
}),
("display right: last window leaves its workspace", {
    let w = windows(5); plug("right"); let ext = other(state)
    let t = w[4].titleBar; seam("drag \(t.x) \(t.y) \(ext.area.midX) \(ext.area.midY)")
    checkFrame("it fills the display", w[4], other(state).area)
    checkWorkspace("the emptied workspace dies", 1); checkShowing("grid back", w[0])
}),
("display right: arrow keys", {
    let w = windows(2); plug("right"); let ext = other(state)
    focus(w[1]); key(right); checkFrame("⌘⌥→ into the empty display", w[1], other(state).area)
    check("no third party") { state.tree(of: w[1].id)?.display == ext.display }
    focus(w[0]); key(right); check("⌘⌥→ onto a tile swaps") { state.tree(of: w[0].id)?.display == ext.display }
    checkFrame("swapped window fills the bigger display", w[0], other(state).area)
    checkFrame("and the other fits the smaller", w[1], part(main, 0, 0, 1, 1))
    focus(w[0]); key(right); check("past the last display nothing happens") { state.tree(of: w[0].id)?.display == ext.display }
    focus(w[0]); key(up); check("up with nothing there does nothing") { state.tree(of: w[0].id)?.display == ext.display }
}),
("display right: edge drop and full display", {
    let w = windows(5); plug("right"); let ext = other(state)
    goTo(1); focus(w[0]); key(right); usleep(400_000)
    let e = other(state).area, t = w[1].titleBar
    seam("drag \(t.x) \(t.y) \(e.maxX - 30) \(e.midY)")
    check("edge drop splits on the display") { state.tree(of: w[1].id)?.display == ext.display }
    checkInvariants()
}),
("display right: independent workspaces and parking", {
    let w = windows(5); plug("right"); usleep(500_000)
    let s = state, ext = other(s)
    goTo(1); usleep(300_000); seam("sync"); seam("sync"); usleep(800_000); seam("sync")
    check("parked stays in its tree, not pulled to the other display") { state.tree(of: w[4].id)?.display == s.screens[0].display }
    check("parked window is on the main Space") { state.tree(of: w[4].id)?.space == s.screens[0].space }
    let f = w[3]; focus(f); key(right); usleep(500_000)
    let e = windows(1)[0]; focus(f); usleep(200_000); _ = e
    mouse(other(state).area.center); check("cursor on the display") { state.screens.count == 2 }
    goTo(1); check("main unaffected by the other display's keys") { state.screens[0].workspace == 1 }
    _ = ext; checkInvariants()
}),
("display right: workspaces on the external", {
    let m = window(); plug("right"); let ext = other(state)
    let w = (0..<4).map { _ in window(on: other(state).area) }
    check("new windows open where they're put, not beside the focused one") { w.allSatisfy { state.tree(of: $0.id)?.display == ext.display } }
    checkFrame("grid on the external", w[0], part(other(state).area, 0, 0, 0.5, 0.5))
    let fifth = window(on: other(state).area)
    check("fifth on the external opens its workspace 2") { state.tree(of: fifth.id)?.workspace == 2 && state.tree(of: fifth.id)?.display == ext.display }
    check("external shows 2", "\(state.screens.map(\.workspace))") { other(state).workspace == 2 }
    checkWorkspace("main stays on 1", 1); checkShowing("main's window untouched", m); checkFrame("and whole", m, main)
    check("external's parked window hidden and not on main", "\(w[0].frame)") { let s = state; return s.parked.contains(w[0].id) && !s.screens.contains { $0.frame.intersection(w[0].frame).width > 2 && $0.frame.intersection(w[0].frame).height > 2 } }
    mouse(other(state).area.center); goTo(1); check("⌘⌥1 with the cursor there switches that display") { other(state).workspace == 1 }
    checkWorkspace("main didn't move", 1); checkShowing("external grid back", w[0]); checkFrame("in place", w[0], part(other(state).area, 0, 0, 0.5, 0.5))
    focus(w[0]); send(2); check("send works on the external") { state.tree(of: w[0].id)?.workspace == 2 && state.tree(of: w[0].id)?.display == ext.display }
    close(fifth); close(w[0]); check("empty external workspace dies") { state.trees.filter { $0.display == ext.display }.count == 1 }
    checkInvariants()
}),
("display right: drop on a full display swaps", {
    let m = windows(2); plug("right"); let ext = other(state)
    let w = (0..<4).map { _ in window(on: other(state).area) }
    let e = other(state).area, t = m[1].titleBar
    seam("drag \(t.x) \(t.y) \(e.maxX - 20) \(e.midY)")
    check("still four there", "\(state.trees)") { state.trees.first { $0.display == ext.display && $0.workspace == 1 }?.windows.count == 4 }
    check("the dragged window went there") { state.tree(of: m[1].id)?.display == ext.display }
    checkInvariants()
}),
("display right: empty the display by dragging back", {
    let w = windows(2); plug("right"); let e = other(state).area
    let t = w[1].titleBar; seam("drag \(t.x) \(t.y) \(e.midX) \(e.midY)"); checkFrame("over", w[1], other(state).area)
    let b = w[1].titleBar, r = w[0].frame; seam("drag \(b.x) \(b.y) \(r.maxX - 20) \(r.midY)")
    check("back on main") { state.tree(of: w[1].id)?.display == state.screens[0].display }
    checkFrame("half again", w[1], part(main, 0.5, 0, 0.5, 1)); check("no tree left there") { state.trees.count == 1 }
    let t2 = w[1].titleBar; seam("drag \(t2.x) \(t2.y) \(e.midX) \(e.midY)"); checkFrame("and over again", w[1], other(state).area)
}),
("displays left, above, below, small and mixed", {
    for (side, size) in [("left", (1920, 1080)), ("above", (1920, 1080)), ("above", (1280, 800)), ("below", (1920, 1080))] {
        let w = windows(5); plug(side, size); goTo(1); usleep(400_000); seam("sync"); usleep(700_000)
        check("\(side) \(size): parked stays home") { seam("sync").tree(of: w[4].id)?.display == state.screens[0].display }
        check("\(side) \(size): parked not visible on any display", "\(w[4].frame)") {
            let s = state; return !s.screens.contains { $0.frame.intersection(w[4].frame).width > 2 && $0.frame.intersection(w[4].frame).height > 2 }
        }
        let edge = side == "below" ? w[3] : w[0] // the tile next to that display
        focus(edge); key(side == "left" ? left : side == "above" ? up : down)
        checkFrame("\(side) \(size): arrow reaches it", edge, other(state).area)
        goTo(2); usleep(300_000); seam("sync"); usleep(600_000)
        check("\(side) \(size): parked on the other display stays out of sight", "\(w[1].frame)") {
            state.screens[0].workspace == 2 ? !onScreenFully(w[1], state) : true
        }
        reset()
    }
}),
("plugging a display in over parked windows", {
    for side in ["right", "below", "left"] {
        let w = windows(5); goTo(1); usleep(500_000); plug(side); usleep(1_500_000)
        check("\(side): parked window stays out of sight", "\(w[4].frame) screens \(state.screens.map(\.frame))") {
            let s = state; return s.parked.contains(w[4].id) && !s.screens.contains { $0.frame.intersection(w[4].frame).width > 2 && $0.frame.intersection(w[4].frame).height > 2 }
        }
        unplug(); usleep(1_500_000)
        check("\(side): and after unplugging", "\(w[4].frame)") {
            let s = state; return s.parked.contains(w[4].id) && !s.screens.contains { $0.frame.intersection(w[4].frame).width > 2 && $0.frame.intersection(w[4].frame).height > 2 }
        }
        checkFrame("\(side): tiles exactly in place", w[0], part(main, 0, 0, 0.5, 0.5))
        reset()
    }
}),
("unplug with tiles, parked windows and workspaces", {
    let w = windows(5); plug("right"); goTo(1); focus(w[0]); key(right); usleep(500_000)
    unplug(); seam("sync"); usleep(600_000); seam("sync")
    check("all still tracked") { w.allSatisfy { state.tree(of: $0.id) != nil } }
    checkInvariants()
    check("something showing") { w.contains { onScreenFully($0, state) } }
    plug("right"); seam("sync"); usleep(500_000); checkInvariants()
    let more = windows(4); _ = more; unplug(); checkInvariants()
}),
("unplug with five or more on the external", {
    let w = windows(4); plug("right"); for x in w.prefix(3) { focus(x); key(right); usleep(300_000) }
    unplug(); seam("sync"); usleep(600_000); checkInvariants()
    check("all still tracked") { w.allSatisfy { state.tree(of: $0.id) != nil } }
}),
]

// the quit scenarios stop Seam, so they run last and the runner puts the real one back
func quitScenario() {
    scenario = "quit brings parked windows back"
    print("\n\(scenario)")
    let w = windows(6)
    seam("state")
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); task.arguments = ["-x", "Seam"]; try? task.run(); task.waitUntilExit()
    check("every window on screen after quit") { let s = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: 0, width: $0.frame.width, height: $0.frame.height + 40) }; return w.allSatisfy { x in s.contains { $0.intersects(x.frame) && x.frame.minX < $0.maxX - 100 } } }
}

DispatchQueue.global().async {
    manage()
    for (name, run) in scenarios where filter.isEmpty || filter.split(separator: "|").contains(where: { name.contains($0) }) {
        scenario = name
        print("\n\(name)")
        reset(); run(); reset()
    }
    if filter.isEmpty || "quit".contains(filter) { quitScenario() }
    print("\n\(passed) passed, \(failed.count) failed")
    for f in failed { print("  FAIL \(f)") }
    exit(failed.isEmpty ? 0 : 1)
}
app.run()
