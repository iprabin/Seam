import Foundation

/**
 * The layout as a split tree, ported from manga-reader's tiling/tree.ts: a
 * window is a leaf, a split lays its children out along a row or a column
 * with a share each (summing to 1) and a seam between neighbours. Rects are
 * in Accessibility coordinates: top-left origin on the main display.
 */
enum Dir { case row, column }
/** Where a dragged window lands on another: beside it, or in its place. */
enum Zone { case left, right, top, bottom, center }

indirect enum Node: Equatable {
    case leaf(Int)
    case split(Dir, [Node], [Double])
}

/** Space between tiles and around them; 0 = edge to edge, by the user's choice. */
let gap: CGFloat = 0
let minPane: CGFloat = 200

func leaves(_ node: Node) -> [Int] {
    switch node {
    case .leaf(let id): return [id]
    case .split(_, let children, _): return children.flatMap(leaves)
    }
}

private func even(_ dir: Dir, _ children: [Node]) -> Node {
    .split(dir, children, children.map { _ in 1 / Double(children.count) })
}

/** A new window joins the outermost split, and every share there evens out. */
func appendLeaf(_ root: Node, _ id: Int) -> Node {
    switch root {
    case .leaf: return even(.row, [root, .leaf(id)])
    case let .split(dir, children, _): return even(dir, children + [.leaf(id)])
    }
}

/** Its neighbours split its share; a split left with one child is replaced by it. */
func removeLeaf(_ node: Node, _ id: Int) -> Node? {
    guard case let .split(dir, children, sizes) = node else { return node == .leaf(id) ? nil : node }
    var kept: [Node] = [], keptSizes: [Double] = []
    for (child, size) in zip(children, sizes) {
        if let child = removeLeaf(child, id) {
            kept.append(child)
            keptSizes.append(size)
        }
    }
    if kept.isEmpty { return nil }
    if kept.count == 1 { return kept[0] }
    let sum = keptSizes.reduce(0, +)
    return .split(dir, kept, keptSizes.map { $0 / sum })
}

func swapLeaves(_ node: Node, _ a: Int, _ b: Int) -> Node {
    switch node {
    case .leaf(let id): return .leaf(id == a ? b : id == b ? a : id)
    case let .split(dir, children, sizes): return .split(dir, children.map { swapLeaves($0, a, b) }, sizes)
    }
}

/** Swaps two windows, and their shares too when they sit in the same split, so each keeps its size. */
func swapPlaces(_ root: Node, _ a: Int, _ b: Int) -> Node {
    let swapped = swapLeaves(root, a, b)
    guard var pa = path(to: a, in: root), var pb = path(to: b, in: root),
          let i = pa.popLast(), let j = pb.popLast(), pa == pb else { return swapped }
    return updatingSizes(swapped, at: pa[...]) { $0.swapAt(i, j) }
}

/**
 * Window `id` beside `target` on `zone`'s side. Inside a split that already
 * runs that way it joins it and halves the target's share; otherwise the
 * target splits in two.
 */
func insertBeside(_ node: Node, _ target: Int, _ id: Int, _ zone: Zone) -> Node {
    let dir: Dir = zone == .left || zone == .right ? .row : .column
    let first = zone == .left || zone == .top
    switch node {
    case .leaf(let leaf):
        guard leaf == target else { return node }
        return even(dir, first ? [.leaf(id), node] : [node, .leaf(id)])
    case .split(let d, var children, var sizes):
        if d == dir, let i = children.firstIndex(of: .leaf(target)) {
            let at = first ? i : i + 1
            sizes[i] /= 2
            children.insert(.leaf(id), at: at)
            sizes.insert(sizes[i], at: at)
            return .split(d, children, sizes)
        }
        return .split(d, children.map { insertBeside($0, target, id, zone) }, sizes)
    }
}

/** Dropping window `id` on `target`: the middle swaps them, an edge moves it there. */
func dropLeaf(_ root: Node, _ id: Int, _ target: Int, _ zone: Zone) -> Node {
    if id == target { return root }
    if zone == .center { return swapLeaves(root, id, target) }
    return removeLeaf(root, id).map { insertBeside($0, target, id, zone) } ?? root
}

/** Child indices from the root down to leaf `id`. */
func path(to id: Int, in node: Node) -> [Int]? {
    switch node {
    case .leaf(let leaf): return leaf == id ? [] : nil
    case .split(_, let children, _):
        for (i, child) in children.enumerated() {
            if let rest = path(to: id, in: child) { return [i] + rest }
        }
        return nil
    }
}

func sizes(at path: ArraySlice<Int>, in node: Node) -> [Double]? {
    guard case let .split(_, children, sizes) = node else { return nil }
    guard let first = path.first else { return sizes }
    return Seam.sizes(at: path.dropFirst(), in: children[first])
}

func updatingSizes(_ node: Node, at path: ArraySlice<Int>, _ change: (inout [Double]) -> Void) -> Node {
    guard case .split(let dir, var children, var sizes) = node else { return node }
    if let first = path.first {
        children[first] = updatingSizes(children[first], at: path.dropFirst(), change)
    } else {
        change(&sizes)
    }
    return .split(dir, children, sizes)
}

func node(at path: ArraySlice<Int>, in root: Node) -> Node? {
    guard let first = path.first else { return root }
    guard case let .split(_, children, _) = root else { return nil }
    return node(at: path.dropFirst(), in: children[first])
}

func updating(_ root: Node, at path: ArraySlice<Int>, _ change: (Node) -> Node) -> Node {
    guard let first = path.first else { return change(root) }
    guard case .split(let dir, var children, let sizes) = root else { return root }
    children[first] = updating(children[first], at: path.dropFirst(), change)
    return .split(dir, children, sizes)
}

func isStacked(_ root: Node, _ id: Int) -> Bool {
    guard var at = path(to: id, in: root), at.popLast() != nil, case .split(.column, _, _)? = node(at: at[...], in: root) else { return false }
    return true
}

/** Takes `id` out of its stack and puts it beside that stack: undoes stacking. */
func unstack(_ root: Node, _ id: Int) -> Node {
    guard isStacked(root, id), var at = path(to: id, in: root), let j = at.popLast(),
          let without = removeLeaf(root, id) else { return root }
    // what's left of the stack is still at `at`; a row around it takes the window in
    // beside it (left if it was the stack's top, so stack-then-unstack round-trips),
    // and every column of that row evens out
    let left = j == 0
    let parent = at.dropLast()
    if let i = at.last, case .split(.row, var children, _)? = node(at: parent, in: without) {
        children.insert(.leaf(id), at: left ? i : i + 1)
        return updating(without, at: parent) { _ in even(.row, children) }
    }
    return updating(without, at: at[...]) { even(.row, left ? [.leaf(id), $0] : [$0, .leaf(id)]) }
}

/** Every split shares out evenly, like i3's `balance`. */
func balanced(_ node: Node) -> Node {
    guard case let .split(dir, children, _) = node else { return node }
    return even(dir, children.map(balanced))
}

/** Turns the split at `path` from a row into a column or back, like i3's `layout toggle split`. */
func flipSplit(_ node: Node, at path: ArraySlice<Int>) -> Node {
    guard case .split(let dir, var children, let sizes) = node else { return node }
    guard let first = path.first else { return .split(dir == .row ? .column : .row, children, sizes) }
    children[first] = flipSplit(children[first], at: path.dropFirst())
    return .split(dir, children, sizes)
}

/** Between visible children `a` and `b` of the split at `path`. */
struct SeamInfo {
    var path: [Int]
    var a: Int
    var b: Int
    var dir: Dir
    var rect: CGRect
    /** Pixels per unit of share, to turn a drag into shares. */
    var pxPerShare: CGFloat
}

struct Layout {
    var panes: [Int: CGRect] = [:]
    var seams: [SeamInfo] = []
}

/**
 * Every visible window's rect and every seam. A hidden window (minimised, on
 * another Space, app hidden) keeps its place in the tree but takes no room,
 * so it comes back where it was. `minSize` is each window's smallest size its
 * app allows: a child below its minimum gets exactly that, and the rest share
 * what's left by their shares. If the minimums don't fit, windows overlap.
 */
func layout(_ node: Node, in rect: CGRect, visible: (Int) -> Bool, minSize: (Int) -> CGSize = { _ in .zero },
            path: [Int] = [], into out: inout Layout) {
    switch node {
    case .leaf(let id):
        if visible(id) { out.panes[id] = rect }
    case let .split(dir, children, sizes):
        let shown = children.indices.filter { leaves(children[$0]).contains(where: visible) }
        guard !shown.isEmpty else { return }
        let row = dir == .row
        let total = shown.reduce(0) { $0 + sizes[$1] }
        let length = (row ? rect.width : rect.height) - gap * CGFloat(shown.count - 1)
        let pxPerShare = length / CGFloat(total)
        // pin children to their minimums until the rest, shared out, all clear theirs
        let mins = shown.map { minLength(children[$0], dir, visible, minSize) }
        var pinned = Set<Int>()
        var px = shown.map { pxPerShare * CGFloat(sizes[$0]) }
        for _ in shown {
            let free = length - pinned.reduce(0) { $0 + mins[$1] }
            let freeShares = shown.indices.filter { !pinned.contains($0) }.reduce(0) { $0 + sizes[shown[$1]] }
            for k in shown.indices where !pinned.contains(k) { px[k] = free * CGFloat(sizes[shown[k]] / freeShares) }
            let under = shown.indices.filter { !pinned.contains($0) && px[$0] < mins[$0] }
            if under.isEmpty { break }
            for k in under { pinned.insert(k); px[k] = mins[k] }
            if pinned.count == shown.count { break }
        }
        let end = row ? rect.maxX : rect.maxY
        var offset = row ? rect.minX : rect.minY
        for (n, i) in shown.enumerated() {
            let last = n == shown.count - 1
            let size = last ? end - offset : px[n].rounded()
            let child = row
                ? CGRect(x: offset, y: rect.minY, width: size, height: rect.height)
                : CGRect(x: rect.minX, y: offset, width: rect.width, height: size)
            layout(children[i], in: child, visible: visible, minSize: minSize, path: path + [i], into: &out)
            offset += size
            if !last {
                let seam = row
                    ? CGRect(x: offset, y: rect.minY, width: gap, height: rect.height)
                    : CGRect(x: rect.minX, y: offset, width: rect.width, height: gap)
                out.seams.append(SeamInfo(path: path, a: i, b: shown[n + 1], dir: dir, rect: seam, pxPerShare: pxPerShare))
                offset += gap
            }
        }
    }
}

/** The least room `node` needs along `dir`: side by side adds up, stacked takes the largest. */
func minLength(_ node: Node, _ dir: Dir, _ visible: (Int) -> Bool, _ minSize: (Int) -> CGSize) -> CGFloat {
    switch node {
    case .leaf(let id):
        guard visible(id) else { return 0 }
        let size = minSize(id)
        return dir == .row ? size.width : size.height
    case let .split(d, children, _):
        let shown = children.filter { leaves($0).contains(where: visible) }
        let each = shown.map { minLength($0, dir, visible, minSize) }
        return d == dir ? each.reduce(0, +) + gap * CGFloat(max(shown.count - 1, 0)) : each.max() ?? 0
    }
}

/** The window under a point, other than `except`; tiles never overlap. */
func paneAt(_ panes: [Int: CGRect], _ point: CGPoint, except: Int) -> Int? {
    panes.first { $0.key != except && $0.value.contains(point) }?.key
}

/** Which part of `rect` the point is in: its middle, or the nearest edge. */
func zoneAt(_ rect: CGRect, _ point: CGPoint) -> Zone {
    let dx = (point.x - rect.minX) / rect.width
    let dy = (point.y - rect.minY) / rect.height
    if dx > 0.3 && dx < 0.7 && dy > 0.3 && dy < 0.7 { return .center }
    return [(Zone.left, dx), (.right, 1 - dx), (.top, dy), (.bottom, 1 - dy)].min { $0.1 < $1.1 }!.0
}

/** The part of `rect` a drop on `zone` would take. */
func zoneRect(_ r: CGRect, _ zone: Zone) -> CGRect {
    switch zone {
    case .left: return CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
    case .right: return CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
    case .top: return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
    case .bottom: return CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
    case .center: return r
    }
}

/** `Seam --selftest`: the tree logic, without touching any windows. */
func treeSelfTest() {
    let two = appendLeaf(.leaf(1), 2)
    precondition(two == .split(.row, [.leaf(1), .leaf(2)], [0.5, 0.5]), "second window")
    let stacked = dropLeaf(two, 3, 2, .bottom)
    precondition(stacked == .split(.row, [.leaf(1), .split(.column, [.leaf(2), .leaf(3)], [0.5, 0.5])], [0.5, 0.5]), "one beside two stacked")
    precondition(dropLeaf(two, 3, 2, .right) == .split(.row, [.leaf(1), .leaf(2), .leaf(3)], [0.5, 0.25, 0.25]), "join a row")
    precondition(leaves(dropLeaf(stacked, 1, 3, .center)) == [3, 2, 1], "middle swaps")
    precondition(dropLeaf(stacked, 3, 1, .left) == .split(.row, [.leaf(3), .leaf(1), .leaf(2)], [0.25, 0.25, 0.5]), "move across")
    precondition(removeLeaf(stacked, 3) == two, "closing collapses the split")
    precondition(removeLeaf(.leaf(1), 1) == nil, "last window")
    precondition(path(to: 3, in: stacked) == [1, 1], "path")
    precondition(unstack(stacked, 3) == .split(.row, [.leaf(1), .leaf(2), .leaf(3)], [1.0 / 3, 1.0 / 3, 1.0 / 3]), "unstack into the row, evened out")
    let column: Node = .split(.column, [.leaf(1), .leaf(2)], [0.5, 0.5])
    precondition(unstack(column, 2) == two, "unstack a stack at the root")
    precondition(unstack(column, 1) == two, "unstacking the top keeps it left")
    precondition(unstack(stacked, 2) == .split(.row, [.leaf(1), .leaf(2), .leaf(3)], [1.0 / 3, 1.0 / 3, 1.0 / 3]), "top of an inner stack goes left of it")
    precondition(unstack(two, 2) == two, "not stacked: nothing to undo")
    let uneven: Node = .split(.row, [.leaf(1), .leaf(2), .leaf(3)], [0.5, 0.3, 0.2])
    let nested: Node = .split(.row, [.leaf(4), .split(.column, [.leaf(5), .leaf(6)], [0.9, 0.1])], [0.8, 0.2])
    precondition(balanced(nested) == .split(.row, [.leaf(4), .split(.column, [.leaf(5), .leaf(6)], [0.5, 0.5])], [0.5, 0.5]), "balance evens every split")
    precondition(swapPlaces(uneven, 1, 3) == .split(.row, [.leaf(3), .leaf(2), .leaf(1)], [0.2, 0.3, 0.5]), "sizes travel with windows")
    precondition(swapPlaces(stacked, 1, 3) == swapLeaves(stacked, 1, 3), "different splits keep the slots")
    precondition(flipSplit(stacked, at: [1]) == .split(.row, [.leaf(1), .split(.row, [.leaf(2), .leaf(3)], [0.5, 0.5])], [0.5, 0.5]), "flip inner split")
    precondition(flipSplit(two, at: []) == .split(.column, [.leaf(1), .leaf(2)], [0.5, 0.5]), "flip root")

    let area = CGRect(x: 0, y: 0, width: 200 + gap, height: 100)
    var out = Layout()
    layout(two, in: area, visible: { _ in true }, into: &out)
    precondition(out.panes[1] == CGRect(x: 0, y: 0, width: 100, height: 100), "left tile")
    precondition(out.panes[2] == CGRect(x: 100 + gap, y: 0, width: 100, height: 100), "right tile after the gap")
    precondition(out.seams.count == 1 && out.seams[0].rect.minX == 100, "seam between them")
    out = Layout()
    layout(two, in: area, visible: { $0 == 2 }, into: &out)
    precondition(out.panes == [2: area] && out.seams.isEmpty, "hidden window takes no room")
    // 4 across 400 wide, the second can't go under 160: it gets 160, the other three share 240
    let four: Node = .split(.row, (1...4).map { .leaf($0) }, [0.25, 0.25, 0.25, 0.25])
    out = Layout()
    layout(four, in: CGRect(x: 0, y: 0, width: 400 + 3 * gap, height: 100), visible: { _ in true },
           minSize: { $0 == 2 ? CGSize(width: 160, height: 0) : .zero }, into: &out)
    precondition(out.panes[2]!.width == 160 && out.panes[1]!.width == 80 && out.panes[4]!.width == 80, "minimum width honoured")
    precondition(minLength(stacked, .row, { _ in true }, { _ in CGSize(width: 50, height: 70) }) == 100 + gap, "row adds up")
    precondition(minLength(stacked, .column, { _ in true }, { _ in CGSize(width: 50, height: 70) }) == 140 + gap, "stack adds up inside")

    precondition(zoneAt(area, CGPoint(x: 104, y: 50)) == .center && zoneAt(area, CGPoint(x: 5, y: 50)) == .left, "zones")
    print("selftest ok")
}
