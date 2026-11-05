import Foundation

// The layout as a split tree (port of manga-reader's tiling/tree.ts): a window is a leaf, a split lays
// its children out along a row or column with shares summing to 1. Rects are in AX coordinates (top-left origin).
enum Dir { case row, column }
/** Where a dragged window lands on another: beside it, or in its place. */
enum Zone { case left, right, top, bottom, center }

indirect enum Node: Equatable {
    case leaf(Int)
    case split(Dir, [Node], [Double])
}

/** Space between tiles; 0 by the user's choice. */
let gap: CGFloat = 0
let minPane: CGFloat = 200
/** Quarters are the smallest tile; the next window opens the next workspace. */
let maxTiles = 4

func leaves(_ node: Node) -> [Int] {
    switch node {
    case .leaf(let id): return [id]
    case .split(_, let children, _): return children.flatMap(leaves)
    }
}

private func even(_ dir: Dir, _ children: [Node]) -> Node {
    .split(dir, children, children.map { _ in 1 / Double(children.count) })
}

/** Neighbours take its share; a split left with one child collapses into it. */
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

/** Like `swapLeaves`, but windows in the same split keep their sizes. */
func swapPlaces(_ root: Node, _ a: Int, _ b: Int) -> Node {
    let swapped = swapLeaves(root, a, b)
    guard var pa = path(to: a, in: root), var pb = path(to: b, in: root),
          let i = pa.popLast(), let j = pb.popLast(), pa == pb else { return swapped }
    return updatingSizes(swapped, at: pa[...]) { $0.swapAt(i, j) }
}

/** `id` beside `target`: joins a split already running that way (halving the target's share), else splits the target in two. */
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

/** The first workspace from `start` on with room for one more. */
func workspaceWithRoom(from start: Int, tiles: (Int) -> Int) -> Int {
    (start...).first { tiles($0) < maxTiles } ?? start
}

/** Where to go from a workspace that emptied: the closest with windows, the lower of equals. */
func nearestWorkspace(to n: Int, among occupied: [Int]) -> Int? {
    occupied.min { (abs($0 - n), $0) < (abs($1 - n), $1) }
}

/** How a new window splits a tile: along its longer side like yabai, but side by side only across the whole display, so two columns at most. */
func splitZone(_ tile: CGRect, in area: CGRect) -> Zone {
    tile.width >= tile.height && tile.width >= area.width - 2 ? .right : .bottom
}

/** Splits the biggest tile, the rightmost then lowest of equals: 1 | ½ over ½, then ½ ½ over ½ ½. */
func addWindow(_ tree: Node, _ id: Int, in area: CGRect, visible: (Int) -> Bool = { _ in true }) -> Node {
    var out = Layout()
    layout(tree, in: area, visible: visible, into: &out)
    let size = { (r: CGRect) in r.width * r.height }
    let most = out.panes.values.map(size).max() ?? 0
    // 2%: a rounded pixel doesn't decide a tie
    let biggest = out.panes.filter { size($0.value) >= most * 0.98 }
    guard let (at, rect) = biggest.max(by: { ($0.value.maxX, $0.value.maxY) < ($1.value.maxX, $1.value.maxY) }) else { return tree }
    return insertBeside(tree, at, id, splitZone(rect, in: area))
}

/** Centre swaps, an edge moves `id` there. */
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

/** Takes `id` out of its stack and puts it beside it, left if it was the top so stack-then-unstack round-trips. */
func unstack(_ root: Node, _ id: Int) -> Node {
    guard isStacked(root, id), var at = path(to: id, in: root), let j = at.popLast(),
          let without = removeLeaf(root, id) else { return root }
    let left = j == 0
    let parent = at.dropLast()
    if let i = at.last, case .split(.row, var children, _)? = node(at: parent, in: without) {
        children.insert(.leaf(id), at: left ? i : i + 1)
        return updating(without, at: parent) { _ in even(.row, children) }
    }
    return updating(without, at: at[...]) { even(.row, left ? [.leaf(id), $0] : [$0, .leaf(id)]) }
}

/** Every split evened out (i3 `balance`). */
func balanced(_ node: Node) -> Node {
    guard case let .split(dir, children, _) = node else { return node }
    return even(dir, children.map(balanced))
}

/** Row ⇄ column at `path` (i3 `layout toggle split`). */
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
    var pxPerShare: CGFloat
}

struct Layout {
    var panes: [Int: CGRect] = [:]
    var seams: [SeamInfo] = []
}

/**
 * Every visible window's rect and every seam. A hidden window keeps its place but takes no room.
 * A child is held between its `minSize` and `maxSize`; the rest share what's left. Minimums that don't fit overlap.
 */
func layout(_ node: Node, in rect: CGRect, visible: (Int) -> Bool, minSize: (Int) -> CGSize = { _ in .zero },
            maxSize: (Int) -> CGSize = { _ in .unbounded }, path: [Int] = [], into out: inout Layout) {
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
        // bisect t (px per share) until the clamped children fill the length
        let mins = shown.map { minLength(children[$0], dir, visible, minSize) }
        let maxs = shown.map { minLength(children[$0], dir, visible, maxSize) }
        let fill = { (t: CGFloat) in shown.indices.map { min(max(t * CGFloat(sizes[shown[$0]]), mins[$0]), max(maxs[$0], mins[$0])) } }
        var lo: CGFloat = 0, hi = length / CGFloat(max(shown.map { sizes[$0] }.min() ?? 1, 1e-9))
        for _ in 0..<50 { let t = (lo + hi) / 2; if fill(t).reduce(0, +) < length { lo = t } else { hi = t } }
        let px = fill(hi)
        let end = row ? rect.maxX : rect.maxY
        var offset = row ? rect.minX : rect.minY
        for (n, i) in shown.enumerated() {
            let last = n == shown.count - 1
            let size = last ? end - offset : px[n].rounded()
            let child = row
                ? CGRect(x: offset, y: rect.minY, width: size, height: rect.height)
                : CGRect(x: rect.minX, y: offset, width: rect.width, height: size)
            layout(children[i], in: child, visible: visible, minSize: minSize, maxSize: maxSize, path: path + [i], into: &out)
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

/** Least room along `dir`: same direction adds up, across takes the largest. */
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

func paneAt(_ panes: [Int: CGRect], _ point: CGPoint, except: Int) -> Int? {
    panes.first { $0.key != except && $0.value.contains(point) }?.key
}

/** The middle of `rect`, or its nearest edge. */
func zoneAt(_ rect: CGRect, _ point: CGPoint) -> Zone {
    let dx = (point.x - rect.minX) / rect.width
    let dy = (point.y - rect.minY) / rect.height
    if (0.3..<0.7).contains(dx), (0.3..<0.7).contains(dy) { return .center }
    let edges: [(Zone, CGFloat)] = [(.left, dx), (.right, 1 - dx), (.top, dy), (.bottom, 1 - dy)]
    return edges.min { $0.1 < $1.1 }?.0 ?? .center
}

func zoneRect(_ r: CGRect, _ zone: Zone) -> CGRect {
    switch zone {
    case .left: return CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
    case .right: return CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
    case .top: return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
    case .bottom: return CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
    case .center: return r
    }
}

/** `Seam --selftest` */
func treeSelfTest() {
    let two = insertBeside(.leaf(1), 1, 2, .right)
    precondition(two == .split(.row, [.leaf(1), .leaf(2)], [0.5, 0.5]), "second window")
    let wide = CGRect(x: 0, y: 0, width: 3440, height: 1440), tall = CGRect(x: 0, y: 0, width: 1080, height: 1920)
    precondition(splitZone(wide, in: wide) == .right, "the second window goes beside the first")
    precondition(splitZone(CGRect(x: 0, y: 0, width: 1720, height: 1440), in: wide) == .bottom, "no third column, even on an ultrawide")
    precondition(splitZone(CGRect(x: 0, y: 0, width: 1720, height: 720), in: wide) == .bottom, "nor from a wide tile in a column")
    precondition(splitZone(tall, in: tall) == .bottom, "a portrait display stacks first")
    let added = (2...4).reduce(into: [Node.leaf(1)]) { $0.append(addWindow($0[$0.count - 1], $1, in: wide)) }
    precondition(added[1] == two, "two: side by side")
    precondition(workspaceWithRoom(from: 1) { [1: 4, 2: 3][$0] ?? 0 } == 2, "a fifth window goes to the next with room")
    precondition(workspaceWithRoom(from: 1) { [1: 4, 2: 4][$0] ?? 0 } == 3, "past full ones")
    precondition(workspaceWithRoom(from: 2) { _ in 0 } == 2, "room here: stays")
    precondition(nearestWorkspace(to: 3, among: [1, 2, 5]) == 2, "closest")
    precondition(nearestWorkspace(to: 3, among: [2, 4]) == 2, "the lower of equals")
    precondition(nearestWorkspace(to: 1, among: []) == nil, "nothing left")
    precondition(added[2] == .split(.row, [.leaf(1), .split(.column, [.leaf(2), .leaf(3)], [0.5, 0.5])], [0.5, 0.5]), "three: 1 | ½ over ½")
    precondition(added[3] == .split(.row, [.split(.column, [.leaf(1), .leaf(4)], [0.5, 0.5]), .split(.column, [.leaf(2), .leaf(3)], [0.5, 0.5])], [0.5, 0.5]), "four: a 2×2 grid")
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
    let four: Node = .split(.row, (1...4).map { .leaf($0) }, [0.25, 0.25, 0.25, 0.25])
    out = Layout()
    layout(four, in: CGRect(x: 0, y: 0, width: 400 + 3 * gap, height: 100), visible: { _ in true },
           minSize: { $0 == 2 ? CGSize(width: 160, height: 0) : .zero }, into: &out)
    precondition(out.panes[2]!.width == 160 && out.panes[1]!.width == 80 && out.panes[4]!.width == 80, "minimum width honoured")
    out = Layout()
    layout(four, in: CGRect(x: 0, y: 0, width: 400 + 3 * gap, height: 100), visible: { _ in true },
           maxSize: { $0 == 3 ? CGSize(width: 40, height: CGFloat.infinity) : .unbounded }, into: &out)
    precondition(out.panes[3]!.width == 40 && out.panes[1]!.width == 120 && out.panes[4]!.width == 120, "maximum width honoured")
    precondition(minLength(stacked, .row, { _ in true }, { _ in CGSize(width: 50, height: 70) }) == 100 + gap, "row adds up")
    precondition(minLength(stacked, .column, { _ in true }, { _ in CGSize(width: 50, height: 70) }) == 140 + gap, "stack adds up inside")

    precondition(zoneAt(area, CGPoint(x: 104, y: 50)) == .center && zoneAt(area, CGPoint(x: 5, y: 50)) == .left, "zones")
    print("selftest ok")
}
