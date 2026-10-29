import AppKit

extension Tiler {
    // MARK: mouse

    func mouseDragged() {
        mouseMoved = true
        guard let dragging else { return }
        let point = mouseAX()
        guard let target = pane(at: point, except: dragging), let rect = layouts.values.lazy.compactMap({ $0.panes[target] }).first else {
            if drop != nil { drop = nil; overlay.orderOut(nil) }
            return
        }
        let zone = zoneAt(rect, point)
        guard drop.map({ $0 != (target, zone) }) ?? true else { return }
        drop = (target, zone)
        overlay.setFrame(flip(zoneRect(rect, zone)), display: true)
        overlay.orderFrontRegardless()
    }

    func mouseUp() {
        mouseMoved = false
        guard dragging != nil || resizing != nil else { return }
        if let id = dragging, let drop { move(id, onto: drop.target, drop.zone) }
        if let id = resizing { resizeFromEdges(id) }
        for id in [dragging, resizing].compactMap({ $0 }) { applied[id] = nil }
        dragging = nil
        resizing = nil
        drop = nil
        overlay.orderOut(nil)
        relayout()
    }

    func move(_ id: Int, onto target: Int, _ zone: Zone) {
        guard let from = treeKey(of: id), let to = treeKey(of: target), let toTree = trees[to] else { return }
        if zone == .center { // across every tree, so across displays too
            trees = trees.mapValues { swapPlaces($0, id, target) }
        } else if from == to {
            trees[to] = dropLeaf(toTree, id, target, zone)
        } else {
            trees[from] = trees[from].flatMap { removeLeaf($0, id) }
            trees[to] = insertBeside(toTree, target, id, zone)
        }
    }

    /** A moved edge moves the seam on that side. */
    func resizeFromEdges(_ id: Int) {
        guard let key = treeKey(of: id), let old = layouts[key]?.panes[id], let new = windowFrame(id) else { return }
        let edges: [(Dir, CGFloat, CGFloat)] = [
            (.row, old.minX, new.minX), (.row, old.maxX, new.maxX),
            (.column, old.minY, new.minY), (.column, old.maxY, new.maxY),
        ]
        var moved = false
        for (dir, was, now) in edges where abs(now - was) > 2 {
            guard let seam = seam(key, beside: old, dir, at: was) else { continue }
            moveSeam(key, seam, by: now - was)
            moved = true
        }
        if moved { relayout() }
    }

    func seam(_ key: TreeKey, beside tile: CGRect, _ dir: Dir, at edge: CGFloat) -> SeamInfo? {
        layouts[key]?.seams.first { s in
            let row = dir == .row
            let (near, far) = row ? (s.rect.minX, s.rect.maxX) : (s.rect.minY, s.rect.maxY)
            let across = row ? tile.midY : tile.midX
            let span = row ? s.rect.minY...s.rect.maxY : s.rect.minX...s.rect.maxX
            return s.dir == dir && (abs(near - edge) < 2 || abs(far - edge) < 2) && span.contains(across)
        }
    }

    /** Trades `px` between the seam's two sides, each stopping at `minPane`. */
    func moveSeam(_ key: TreeKey, _ seam: SeamInfo, by px: CGFloat) {
        guard let tree = trees[key], let shares = sizes(at: seam.path[...], in: tree) else { return }
        let before = shares[seam.a], pair = before + shares[seam.b]
        let least = Double(minPane / seam.pxPerShare)
        let size = min(max(before + Double(px / seam.pxPerShare), least), pair - least)
        trees[key] = updatingSizes(tree, at: seam.path[...]) { sizes in
            sizes[seam.a] = size
            sizes[seam.b] = pair - size
        }
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

    static func makeBorder() -> NSWindow {
        let window = makeOverlay()
        window.backgroundColor = .clear
        window.contentView = Outline()
        // one Space only, so it slides away with the windows on a switch
        window.collectionBehavior = [.moveToActiveSpace, .transient]
        return window
    }
}

/** A rounded rainbow line: a conic colour wheel masked to a stroke. Static: spinning it kept WindowServer redrawing every frame. */
final class Outline: NSView {
    let ring = CALayer(), wheel = CAGradientLayer(), line = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
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
        CATransaction.begin()
        CATransaction.setDisableActions(true) // snap, don't animate, to the new tile
        ring.frame = bounds
        let side = hypot(bounds.width, bounds.height) // covers the corners
        wheel.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        wheel.position = bounds.center
        // ponytail: window corner radius isn't exposed and varies by app; 16 matches most, tune if they don't line up
        line.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 15, cornerHeight: 15, transform: nil)
        CATransaction.commit()
    }
}
