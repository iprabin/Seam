import AppKit

extension Tiler {
    // MARK: mouse

    func mouseDragged() {
        mouseMoved = true
        guard let dragging else { return }
        let point = mouseAX()
        for layout in layouts.values {
            if let target = paneAt(layout.panes, point, except: dragging), let rect = layout.panes[target] {
                let zone = zoneAt(rect, point)
                drop = (target, zone)
                overlay.setFrame(flip(zoneRect(rect, zone)), display: true)
                overlay.orderFrontRegardless()
                return
            }
        }
        drop = nil
        overlay.orderOut(nil)
    }

    func mouseUp() {
        mouseMoved = false
        guard dragging != nil || resizing != nil else { return }
        if let id = dragging, let drop { move(id, onto: drop.target, drop.zone) }
        if let id = resizing { resizeFromEdges(id) }
        // whatever it was dropped on, it snaps into its tile
        for id in [dragging, resizing].compactMap({ $0 }) { applied[id] = nil }
        dragging = nil
        resizing = nil
        drop = nil
        overlay.orderOut(nil)
        relayout()
    }

    func move(_ id: Int, onto target: Int, _ zone: Zone) {
        guard let from = treeKey(of: id), let to = treeKey(of: target) else { return }
        if zone == .center {
            // each tree holds one of the two, so this swaps across displays too
            trees = trees.mapValues { swapPlaces($0, id, target) }
        } else if from == to {
            trees[to] = dropLeaf(trees[to]!, id, target, zone)
        } else {
            trees[from] = trees[from].flatMap { removeLeaf($0, id) }
            trees[to] = insertBeside(trees[to]!, target, id, zone)
        }
    }

    /** Dragging a tile's edge moves the seam on that side, as dragging the seam would. */
    func resizeFromEdges(_ id: Int) {
        guard let key = treeKey(of: id), let old = layouts[key]?.panes[id], let new = windows[id]?.frame else { return }
        let edges: [(Dir, CGFloat, CGFloat)] = [
            (.row, old.minX, new.minX), (.row, old.maxX, new.maxX),
            (.column, old.minY, new.minY), (.column, old.maxY, new.maxY),
        ]
        for (dir, was, now) in edges where abs(now - was) > 2 {
            if let seam = seam(key, beside: old, dir, at: was) { moveSeam(key, seam, by: now - was) }
        }
    }

    /** The seam running along `tile`'s edge at `edge`. */
    func seam(_ key: TreeKey, beside tile: CGRect, _ dir: Dir, at edge: CGFloat) -> SeamInfo? {
        layouts[key]?.seams.first { s in
            let row = dir == .row
            let (near, far) = row ? (s.rect.minX, s.rect.maxX) : (s.rect.minY, s.rect.maxY)
            let across = row ? tile.midY : tile.midX
            let span = row ? s.rect.minY...s.rect.maxY : s.rect.minX...s.rect.maxX
            return s.dir == dir && (abs(near - edge) < 2 || abs(far - edge) < 2) && span.contains(across)
        }
    }

    func moveSeam(_ key: TreeKey, _ seam: SeamInfo, by px: CGFloat) {
        guard let shares = trees[key].flatMap({ sizes(at: seam.path[...], in: $0) }) else { return }
        shift(key, seam, before: shares[seam.a], after: shares[seam.b], by: px)
    }

    /** Trades `px` of room between the seam's two sides; both stop at their minimums. */
    func shift(_ screen: TreeKey, _ seam: SeamInfo, before: Double, after: Double, by px: CGFloat) {
        let pair = before + after
        let least = Double(minPane / seam.pxPerShare)
        let size = min(max(before + Double(px / seam.pxPerShare), least), pair - least)
        trees[screen] = trees[screen].map {
            updatingSizes($0, at: seam.path[...]) { sizes in
                sizes[seam.a] = size
                sizes[seam.b] = pair - size
            }
        }
        relayout()
    }

    // MARK: the drop preview

    static func makeOverlay() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.isReleasedWhenClosed = false
        return window
    }

    /** The outline round the focused tile. */
    static func makeBorder() -> NSWindow {
        let window = makeOverlay()
        window.backgroundColor = .clear
        window.contentView = Outline()
        // belongs to one Space, so it slides away with the windows on a switch; shown again after
        window.collectionBehavior = [.moveToActiveSpace, .transient]
        return window
    }
}

/**
 * A rounded rainbow line just inside its bounds, its colours running round it:
 * a colour wheel behind the line, which masks all but the line. It used to spin;
 * stilled because WindowServer redrew it every frame, all the time.
 */
final class Outline: NSView {
    let ring = CALayer(), wheel = CAGradientLayer(), line = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // red again at the end so the wheel has no seam
        wheel.colors = [NSColor.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemRed].map(\.cgColor)
        wheel.type = .conic
        wheel.startPoint = CGPoint(x: 0.5, y: 0.5)
        wheel.endPoint = CGPoint(x: 0.5, y: 0)
        line.lineWidth = 2
        line.fillColor = nil
        line.strokeColor = NSColor.black.cgColor
        ring.mask = line
        ring.addSublayer(wheel)
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // snap to the new tile rather than animating there
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        // a square wide enough to cover the corners
        let side = hypot(bounds.width, bounds.height)
        wheel.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        wheel.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // ponytail: windows don't expose their corner radius, and it varies by app
        // and macOS version; 16 matches most, tune it if they don't line up
        line.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 15, cornerHeight: 15, transform: nil)
        CATransaction.commit()
    }
}
