# Seam

i3-style auto-tiling window manager for macOS, native Swift, no dependencies.
**Opinionated, zero config**: keys, gaps and float rules are hardcoded on purpose.
Don't add a config file or settings UI unless the user asks.

## Build / run / test

```fish
swift build && .build/debug/Seam --selftest   # tree logic self-check, prints "selftest ok"
./build.sh                                     # release build → build/Seam.app, signed with Apple Development cert
open build/Seam.app                            # needs Accessibility permission (prompts once)
```

Signing with the dev cert (not ad-hoc) keeps the Accessibility grant across rebuilds.
If it stops working after a rebuild: System Settings › Privacy › Accessibility, remove Seam and add it again.
Running `.build/debug/Seam` directly attributes the permission to the terminal instead.

## Features (behaviour the user asked for)

| Feature | Where |
|---|---|
| Auto-tile: new window splits the focused one along its longer side | `Tiler.tile` |
| Resize by dragging the seam (gap) between windows | `SeamView` + `beginSeamDrag`/`moveSeam`/`shift` |
| Resize by dragging a tiled window's edge (converted to a seam move on mouse up) | `resizeFromEdges` |
| Drag a window onto another (like Zen browser): edge = split there, middle = swap, blue preview | `mouseDragged`/`mouseUp`/`move` |
| Float toggle `⌘⌥C` (centres it); dialogs + `floatingApps` always float | `toggleFloat`, `AXUIElement.isStandard` |
| `⌘⌥ ←→↑↓` move/reorder, `⌃⌥⇧ ←→↑↓` focus, `⌘⇧↩` zoom to whole screen, `⌃⌥ -/=` shrink/grow | `registerHotKeys` |
| One tree per display; unplugged display's windows move to main | `trees`, `relayout` |
| Menu bar item: "Retile Everything" (resets state), Quit | bottom of `main.swift` |

User picked `⌘⌥` arrows (reorder), `⌘⌥C` (float) and `⌘⇧↩` (zoom); the rest mirror Raycast's `⌃⌥` window keys. These are
system-wide, so they shadow app shortcuts (e.g. ⌘⌥←→ tab switching in browsers). Raycast's
bindings must be turned off or `RegisterEventHotKey` fails (logged as "shortcut is taken").

## Architecture (2 files)

- `Sources/Seam/Tree.swift`: pure, no AppKit. Port of
  `~/Desktop/Mobile/manga-reader/src/components/tiling/tree.ts` (same semantics, keep them in sync
  conceptually). `Node` = leaf(windowID) | split(dir, children, shares summing to 1).
  `layout()` gives hidden windows zero room but keeps their place, so seam paths always index the
  *real* tree. `treeSelfTest()` holds the asserts; add one there for any tree change.
- `Sources/Seam/main.swift`: everything with side effects.
  - Window identity = `CGWindowID` via private `_AXUIElementGetWindow`.
  - `sync()` rescans all regular apps' AX windows (add new, forget gone), then `relayout()`.
    Called on almost any AX notification; cheap enough, simple and self-healing.
  - `relayout()` computes `layouts` per display and sets frames; `applied` skips windows already
    at their rect (avoids fighting apps and needless AX calls).
  - Visibility = `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` minus native-fullscreen windows,
    which covers minimised, hidden apps and other Spaces.
  - Distinguishing user drags from our own `setFrame`: moved/resized notifications only count
    while the left mouse button is down and no seam drag is active.
  - Seam handles = small borderless `NSWindow`s in the gaps (pooled in `handles`). They paint
    alpha 0.02 because fully clear pixels let clicks fall through.
  - Coordinates: tree/AX use top-left origin of the main display; AppKit is bottom-left. Use `flip()`.

## Known limits / next ideas

- Windows on other Spaces aren't listed by AX → forgotten and re-tiled on return (marked `ponytail:`).
- No animation; frames snap.
- Apps with large minimum sizes overflow their tile.
- No persistence across restarts.
- Not tested yet on real windows by the user at time of writing (2026-10-13): first feedback pending.
