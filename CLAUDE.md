# Seam

i3-style auto-tiling window manager for macOS. Native Swift, no dependencies.

## Rules (from the user)

- Zero config, hardcoded on purpose: no config file or settings UI. Only exception: `floatingApps` (UserDefaults, `⌘⌥⇧C`).
- Every shortcut is ⌘⌥ + key; ⇧ is the only extra modifier allowed. Shortcuts live in `bindings` (Tiler+Keys.swift), which also builds the menu.
- Misbehaving app windows (VLC aspect lock, Device Hub fixed size) are handled in Seam (`minSizes` / `maxSizes` / `centre`), never by changing the app's settings.
- Tiles what yabai tiles (`isStandard`): standard subrole, normal window level, one Space, movable, plus resizable. Everything else floats untouched.
- New windows halve the biggest tile, rightmost on a tie, not the focused one: 1 | ½ over ½, then a 2×2 grid. Two columns at most (`addWindow`, `splitZone`).
- Quarters are the minimum: a fifth window opens the next workspace (`maxTiles`). Workspaces are Seam's own, i3-style (`TreeKey.workspace`), not macOS Spaces: creating a Space or moving another app's window needs SIP off. A workspace exists only while it has windows (`leaveIfEmpty`).
- Gaps are 0. Layout is not persisted. No animation.
- After every change: `./build.sh` and relaunch build/Seam.app.

## Build / run / test

```fish
swift build && .build/debug/Seam --selftest   # tree asserts, prints "selftest ok"
./build.sh                                     # release → build/Seam.app, signed with Apple Development cert
open build/Seam.app                            # needs Accessibility permission
swift icon.swift                               # redraw icon.png
e2e/run.sh                                     # real windows, keys, drags, a virtual display; leaves your windows alone, takes the cursor
```

Dev-cert signing keeps the Accessibility grant across rebuilds. If it breaks: Privacy › Accessibility, remove and re-add Seam. Don't run `.build/debug/Seam` for real use: the permission attributes to the terminal.

## Layout

- `Tree.swift`: pure, no AppKit. `Node` = leaf(windowID) | split(dir, children, shares). `layout()` gives hidden windows zero room but keeps them in the tree, so seam paths always index the real tree. Add an assert to `treeSelfTest()` for any tree change. Conceptual twin of `~/Desktop/Mobile/manga-reader/src/components/tiling/tree.ts`.
- `Tiler` is one class split by file: `Tiler.swift` (state, `sync`, `relayout`, min/max size learning), `Tiler+Mouse.swift` (drag to move/split, edge resize), `Tiler+Keys.swift` (bindings, hotkeys, menu), `AX.swift` (AX helpers, `flip()`, private CGS space calls), `main.swift`.
- One tree per Space per display (`TreeKey`).

## Gotchas (learned the hard way)

- Coordinates: tree/AX are top-left of main display, AppKit bottom-left. Use `flip()`.
- Window ID = `CGWindowID` via private `_AXUIElementGetWindow`. App pid from `NSRunningApplication.pid`, never `processIdentifier` (launcher-started apps read -1).
- Never block on a busy app: `focused` is cached; `showFocus` reads the cache. `sync()` reads `CGWindowList` and asks only apps with unmet windows for AX windows (each ask can take 1s).
- `windowFrame` (window server) reports animations; use the AX `frame` for the outline and min/max learning, or you learn bogus sizes.
- Min sizes are read 0.3s after relayout (`learnMinSizes`); some apps resize late.
- User drags vs our `setFrame`: moved/resized notifications count only while the left button is down, and only for the first window touched in that drag.
- `applied` skips windows already at their rect; cleared on Space switch for windows that moved.
- Native fullscreen Spaces (CGS type 4) are skipped whole.
- New windows wait 0.15s before tiling (`adopt`): apps raise a window or pin it to all desktops after `kAXWindowCreated`, and `isStandard` would read normal. Later than that, `release` gives its first frame back.
- `kAXFocusedWindowChanged` fires for background apps too: only the frontmost app's counts, and `adopt` asks (`focusedID`) instead of trusting the cache.
- A window crossing displays is clamped to the old one until the move lands: `placeAgain` sets its size again after.
- E2E test traps: synthetic arrow keys need the fn and numpad flags or Carbon hotkeys ignore them; a synthetic key's modifiers stick to the next mouse event, so a stuck control-press won't drag; `NSWindow.init` constrains the rect to the main display; only an app's own process can bring it frontmost. Any `deminiaturize` focuses the window, and Seam then follows it.
- A hidden workspace's windows sit at `parkingSpot` of their own display, overlapping other displays least (over another display they'd show and join its Space), still "on screen" to CGWindowList. Quitting (and SIGTERM) must `unparkAll`, or they stay off screen until the next launch retiles them.
