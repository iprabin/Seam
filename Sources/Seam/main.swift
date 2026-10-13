import AppKit

// Seam: i3-style auto tiling for macOS. Opinionated, no config. Every shortcut is
// ⌘⌥ + a key (see `bindings`, which the menu bar item also lists); drag a window
// onto another to split or swap, drag a window's edge to resize.

if CommandLine.arguments.contains("--selftest") {
    treeSelfTest()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tiler = Tiler()

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Seam")
let menu = NSMenu()
tiler.addShortcuts(to: menu)
menu.addItem(.separator())
menu.addItem(withTitle: "Retile Everything", action: #selector(Tiler.retile), keyEquivalent: "").target = tiler
menu.addItem(.separator())
menu.addItem(NSMenuItem(title: "Quit Seam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
statusItem.menu = menu

if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
    tiler.start()
} else {
    // starts as soon as it's allowed in System Settings › Privacy › Accessibility
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
        guard AXIsProcessTrusted() else { return }
        timer.invalidate()
        tiler.start()
    }
}
app.run()
