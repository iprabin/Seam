import AppKit

// Seam: i3-style auto tiling for macOS. Opinionated, no config. See CLAUDE.md.

if CommandLine.arguments.contains("--selftest") {
    treeSelfTest()
    let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1117), size = CGSize(width: 800, height: 600)
    precondition(parkingSpot(laptop, others: [], size: size) == CGPoint(x: 1727, y: 1116), "alone: bottom right")
    let right = CGRect(x: 1728, y: 0, width: 2560, height: 1440), below = CGRect(x: 0, y: 1117, width: 1920, height: 1080)
    precondition(parkingSpot(laptop, others: [right], size: size) == CGPoint(x: -799, y: 1116), "a display on the right: spill left")
    precondition(parkingSpot(right, others: [laptop], size: size) == CGPoint(x: 4287, y: 1439), "a display on the left: spill right")
    precondition(parkingSpot(laptop, others: [below], size: size) == CGPoint(x: 1727, y: -599), "a wider display below: spill over the top")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tiler = Tiler()

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Seam")
statusItem.button?.imagePosition = .imageLeading
let menu = NSMenu()
menu.delegate = tiler
tiler.addShortcuts(to: menu)
menu.addItem(.separator())
menu.addItem(withTitle: "Retile Everything", action: #selector(Tiler.retile), keyEquivalent: "").target = tiler
menu.addItem(.separator())
menu.addItem(NSMenuItem(title: "Quit Seam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
statusItem.menu = menu

// parked windows must come back however Seam goes; after a crash, the next launch retiles them
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in tiler.unparkAll() }
signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { NSApp.terminate(nil) }
terminate.resume()

#if E2E
e2eStart()
#endif

if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
    tiler.start()
} else { // starts once allowed in System Settings › Privacy › Accessibility
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
        guard AXIsProcessTrusted() else { return }
        timer.invalidate()
        tiler.start()
    }
}
app.run()
