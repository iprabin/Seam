# Seam

i3-style auto-tiling window manager for macOS, native Swift, no dependencies.
**Opinionated, zero config**: keys, gaps and float rules are hardcoded on purpose.
Don't add a config file or settings UI unless the user asks.

## Build / run / test

```fish
swift build && .build/debug/Seam --selftest   # tree logic self-check, prints "selftest ok"
./build.sh                                     # release build → build/Seam.app, signed with Apple Development cert
open build/Seam.app                            # needs Accessibility permission (prompts once)
swift icon.swift                               # redraw icon.png (build.sh makes the .icns from it)
```

Signing with the dev cert (not ad-hoc) keeps the Accessibility grant across rebuilds.
If it stops working after a rebuild: System Settings › Privacy › Accessibility, remove Seam and add it again.
Running `.build/debug/Seam` directly attributes the permission to the terminal instead.

## Features (behaviour the user asked for)

| Feature | Where |
|---|---|
| Auto-tile: new window splits the focused one along its longer side | `Tiler.tile` |
| No gaps: tiles sit edge to edge (`gap = 0` in Tree.swift, user's choice) | `gap` |
| Resize by dragging a tiled window's edge; neighbours follow live | `handle` → `resizeFromEdges` → `shift` |
| Drag a window onto another (like Zen browser): edge = split there, middle = swap, blue preview | `mouseDragged`/`mouseUp`/`move` |
| Float toggle `⌘⌥C` (centres it); dialogs, windows opening under `minPane` either way (Finder's Empty Trash popup) + `floatingApps` always float | `toggleFloat`, `AXUIElement.isStandard` |
| `⌘⌥ ←→↑↓` swap places with the window that way (each keeps its size when in the same row/stack, `swapPlaces`), `⌘⌥⇧ ←→↑↓` focus, `⌘⌥↩` zoom to whole screen (tiled or floating), `⌘⌥ -/=` shrink/grow width by 10% of its row, down to its min / up to the others at theirs (`grow`; height in a stack only if no row) | `bindings` |
| `⌘⌥T` flips the focused window's group row ⇄ column (i3 `layout toggle split`) | `flipFocused`, `flipSplit` |
| `⌘⌥S` toggles: pulls the next window in reading order (previous if last) under the focused one; on a stacked window, takes it out beside the stack and evens out that row's widths | `stackNext`, `unstack` |
| `⌘⌥0` evens out every split on the focused window's display (i3 `balance`) and un-squeezes them | `balance`, `balanced` |
| Rainbow outline, colours running round it (static conic gradient; used to spin, stilled for WindowServer GPU;  2px, rounded 16 like windows; user wanted it fun) round the focused window (its real frame, clipped to its screen, so an app minimum spilling past the tile is outlined whole), since zero gaps hide it; none when zoomed or floating | `showFocus`, `border` |
| One tree per desktop (Space) per display (`TreeKey`), so each desktop keeps its own layout; a window moved to another desktop joins its tree; unplugged display's / deleted desktop's windows move to main | `trees`, `relayout`, `sync` |
| Menu bar item lists every shortcut (built from `bindings`, clicking runs it), Retile Everything, Quit | `bindings`, `addShortcuts` |

**Every shortcut is ⌘⌥ + key** (user's rule; ⇧ is the only extra modifier allowed). They are
system-wide, so they shadow app shortcuts (e.g. ⌘⌥←→ tab switching in browsers). Any other app
holding the same combo makes `RegisterEventHotKey` fail (logged as "shortcut is taken").

## Architecture

- `Sources/Seam/Tree.swift`: pure, no AppKit. Port of
  `~/Desktop/Mobile/manga-reader/src/components/tiling/tree.ts` (same semantics, keep them in sync
  conceptually). `Node` = leaf(windowID) | split(dir, children, shares summing to 1).
  `layout()` gives hidden windows zero room but keeps their place, so seam paths always index the
  *real* tree. `treeSelfTest()` holds the asserts; add one there for any tree change.
- Side effects, split by concern (`Tiler` is one class, extended per file):
  - `AX.swift`: `AXUIElement` helpers, coordinate `flip()`, screen lookups.
  - `Tiler.swift`: state, window discovery (`sync`), `relayout`, min-size learning.
  - `Tiler+Mouse.swift`: drag-to-move/split, edge resize, drop preview.
  - `Tiler+Keys.swift`: `Binding`, keyboard actions, hotkey + menu registration.
  - `main.swift`: `--selftest`, menu bar item, Accessibility prompt, run loop.
  - Window identity = `CGWindowID` via private `_AXUIElementGetWindow`.
  - `sync()` rescans every app's AX windows (regular + accessory, so menu bar apps' windows tile) (add new, forget gone), then `relayout()`.
    Called on almost any AX notification; cheap enough, simple and self-healing.
  - `relayout()` computes `layouts` per display and sets frames; `applied` skips windows already
    at their rect (avoids fighting apps and needless AX calls); cleared on a Space switch since windows there may have been reset meanwhile.
  - Visibility = `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` minus native-fullscreen windows,
    which covers minimised, hidden apps and other Spaces.
  - Distinguishing user drags from our own `setFrame`: moved/resized notifications only count
    while the left mouse button is down, and only for the first window touched in that drag
    (the neighbours we resize live also send notifications).
  - Resizing: the edge diff against the window's layout rect becomes a seam shift each
    resized notification; the layout updates, so the next diff is incremental.
  - History: there used to be drag handles (`SeamView`) in the gaps; removed when gaps went to 0
    (see git log). Bring them back if gaps return and the user wants a grab area.
  - Coordinates: tree/AX use top-left origin of the main display; AppKit is bottom-left. Use `flip()`.

## Known limits / next ideas

- Windows on other Spaces aren't listed by AX; `sync` keeps them while the window server (`CGWindowList .optionAll`) still has them. Space IDs come from private CGS calls in `AX.swift` (`spaces()`, `spaces(of:)`), the same ones yabai uses.
- No animation; frames snap.
- Apps that keep a window smaller than its tile (VLC's aspect lock) can't be made to fill it: `centre` puts them in the tile's middle (after `learnMinSizes`, and when the app resizes itself) instead of fighting. Fix things like this in Seam, not by changing the app's settings (user's rule, 2026-10-15).
- Apps with a minimum size: 0.3s after a relayout, `learnMinSizes` notices a window that came out
  bigger than its tile, or smaller than a learned minimum (VLC keeps its video aspect, so its "minimum" height follows its width) (read later because some apps resize late; reading at once learned bogus
  minimums), records it in `minSizes`, and lays out again; every tile is at least `minPane` (200) both ways (`Tiler.minSize`); `layout()` pins such children to their minimum
  and shares the rest. Shrinking a window already at its learned minimum forgets it (relearned if
  real); Retile Everything clears them all. `⌘⌥=` marks the row's other windows `squeezed`:
  their app minimums are ignored (floor `minPane` only), so they run on under the focused window;
  `⌘⌥-` un-squeezes them. Otherwise, if the minimums add up to more than the screen, windows still overlap.
- Layout isn't persisted (user removed it): restarting Seam re-tiles every window from scratch.
- Not tested yet on real windows by the user at time of writing (2026-10-13): first feedback pending.
