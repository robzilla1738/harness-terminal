import Foundation

/// The split-tree algebra: every pure `PaneNode` walk/rewrite `SessionEditor`'s public
/// verbs are built from (split/remove/swap/zoom-adjacent repair, ratio math, layout
/// builders, directional navigation). Mechanically extracted from `SessionEditor.swift`
/// (PR-31) — same members, `private` relaxed to internal for the file split, zero logic
/// change. Nothing here touches `snapshot` or `bumpRevision`; these are tree-in/tree-out
/// helpers, which is what makes them safe to host in an extension file.
extension SessionEditor {
    func split(node: inout PaneNode, targetPaneID: PaneID, direction: SplitDirection) -> PaneID? {
        switch node {
        case let .leaf(leaf) where leaf.id == targetPaneID:
            let newLeaf = PaneLeaf()
            node = .branch(direction: direction, ratio: 0.5, first: .leaf(leaf), second: .leaf(newLeaf))
            return newLeaf.id
        case .branch(let existingDirection, let ratio, var first, var second):
            if let id = split(node: &first, targetPaneID: targetPaneID, direction: direction) {
                node = .branch(direction: existingDirection, ratio: ratio, first: first, second: second)
                return id
            }
            if let id = split(node: &second, targetPaneID: targetPaneID, direction: direction) {
                node = .branch(direction: existingDirection, ratio: ratio, first: first, second: second)
                return id
            }
            return nil
        default:
            return nil
        }
    }

    /// Clone a pane tree keeping surface IDs but assigning fresh pane IDs.
    static func cloneWithFreshPaneIDs(_ node: PaneNode) -> PaneNode {
        switch node {
        case let .leaf(leaf):
            return .leaf(PaneLeaf(id: UUID(), surfaceID: leaf.surfaceID, daemonSurfaceID: leaf.daemonSurfaceID))
        case let .branch(direction, ratio, first, second):
            return .branch(direction: direction, ratio: ratio,
                           first: cloneWithFreshPaneIDs(first), second: cloneWithFreshPaneIDs(second))
        }
    }

    func surfaceID(forPaneID paneID: PaneID, in node: PaneNode) -> SurfaceID? {
        switch node {
        case let .leaf(leaf) where leaf.id == paneID:
            return leaf.surfaceID
        case let .branch(_, _, first, second):
            return surfaceID(forPaneID: paneID, in: first) ?? surfaceID(forPaneID: paneID, in: second)
        default:
            return nil
        }
    }

    /// After a pane leaves a tab (kill / break / join-source), ensure the tab still
    /// has a valid focus: keep the current active pane if it survived, else promote
    /// the MRU pane, else the first remaining leaf.
    func repairActivePane(_ tab: inout Tab, removed paneID: PaneID) {
        let remaining = tab.rootPane.allPaneIDs()
        if let last = tab.lastActivePaneID, last == paneID || !remaining.contains(last) {
            tab.lastActivePaneID = nil
        }
        if let active = tab.activePaneID, active != paneID, remaining.contains(active) { return }
        tab.activePaneID = tab.lastActivePaneID ?? remaining.first
        tab.lastActivePaneID = nil
    }

    func removePane(_ node: inout PaneNode, target: PaneID) -> Bool {
        switch node {
        case let .leaf(leaf) where leaf.id == target:
            return false
        case .branch(let direction, let ratio, var first, var second):
            if case let .leaf(leaf) = first, leaf.id == target {
                node = second
                return true
            }
            if case let .leaf(leaf) = second, leaf.id == target {
                node = first
                return true
            }
            if removePane(&first, target: target) {
                node = .branch(direction: direction, ratio: ratio, first: first, second: second)
                return true
            }
            if removePane(&second, target: target) {
                node = .branch(direction: direction, ratio: ratio, first: first, second: second)
                return true
            }
            return false
        default:
            return false
        }
    }

    /// One-pass leaf swap: each leaf is examined exactly once and reassigned at most
    /// once, so src↔dst exchange correctly whether they live in the same tab or
    /// different tabs. (Replacing by id in two passes does not — see `swapPanes`.)
    func swapLeaves(in node: inout PaneNode, srcID: PaneID, src: PaneLeaf, dstID: PaneID, dst: PaneLeaf) {
        switch node {
        case let .leaf(leaf):
            if leaf.id == srcID {
                node = .leaf(dst)
            } else if leaf.id == dstID {
                node = .leaf(src)
            }
        case .branch(let direction, let ratio, var first, var second):
            swapLeaves(in: &first, srcID: srcID, src: src, dstID: dstID, dst: dst)
            swapLeaves(in: &second, srcID: srcID, src: src, dstID: dstID, dst: dst)
            node = .branch(direction: direction, ratio: ratio, first: first, second: second)
        }
    }

    func leaf(in node: PaneNode, paneID: PaneID) -> PaneLeaf? {
        switch node {
        case let .leaf(leaf) where leaf.id == paneID: return leaf
        case let .branch(_, _, first, second): return leaf(in: first, paneID: paneID) ?? leaf(in: second, paneID: paneID)
        default: return nil
        }
    }

    func replaceLeaf(in node: inout PaneNode, paneID: PaneID, with replacement: PaneLeaf) {
        switch node {
        case let .leaf(leaf) where leaf.id == paneID:
            node = .leaf(replacement)
        case .branch(let direction, let ratio, var first, var second):
            replaceLeaf(in: &first, paneID: paneID, with: replacement)
            replaceLeaf(in: &second, paneID: paneID, with: replacement)
            node = .branch(direction: direction, ratio: ratio, first: first, second: second)
        default:
            break
        }
    }

    @discardableResult
    func adjustRatio(_ node: inout PaneNode, target: PaneID, delta: CGFloat) -> Bool {
        switch node {
        case let .leaf(leaf) where leaf.id == target:
            return true
        case .branch(let direction, var ratio, var first, var second):
            if adjustRatio(&first, target: target, delta: delta) {
                ratio = min(0.9, max(0.1, ratio + delta))
                node = .branch(direction: direction, ratio: ratio, first: first, second: second)
                return true
            }
            if adjustRatio(&second, target: target, delta: delta) {
                ratio = min(0.9, max(0.1, ratio - delta))
                node = .branch(direction: direction, ratio: ratio, first: first, second: second)
                return true
            }
            return false
        default:
            return false
        }
    }

    func setRatio(_ node: inout PaneNode, firstPaneID: PaneID, secondPaneID: PaneID, ratio: Double) -> Bool {
        guard case .branch(let direction, let existingRatio, var first, var second) = node else { return false }
        if firstLeafID(in: first) == firstPaneID, firstLeafID(in: second) == secondPaneID {
            node = .branch(direction: direction, ratio: ratio, first: first, second: second)
            return true
        }
        if setRatio(&first, firstPaneID: firstPaneID, secondPaneID: secondPaneID, ratio: ratio) {
            node = .branch(direction: direction, ratio: existingRatio, first: first, second: second)
            return true
        }
        if setRatio(&second, firstPaneID: firstPaneID, secondPaneID: secondPaneID, ratio: ratio) {
            node = .branch(direction: direction, ratio: existingRatio, first: first, second: second)
            return true
        }
        return false
    }

    func firstLeafID(in node: PaneNode) -> PaneID? {
        switch node {
        case let .leaf(leaf): return leaf.id
        case let .branch(_, _, first, _): return firstLeafID(in: first)
        }
    }

    func pathTo(paneID: PaneID, in node: PaneNode) -> [Int]? {
        switch node {
        case let .leaf(leaf): return leaf.id == paneID ? [] : nil
        case let .branch(_, _, first, second):
            if let sub = pathTo(paneID: paneID, in: first) { return [0] + sub }
            if let sub = pathTo(paneID: paneID, in: second) { return [1] + sub }
            return nil
        }
    }

    func findNeighbor(in root: PaneNode, path: [Int], direction: Command.PaneTarget) -> PaneID? {
        // Walk up until we find a branch whose split axis matches `direction`
        // and we descended from the side opposite the direction we want.
        var cursor = root
        var ancestors: [(direction: SplitDirection, came: Int)] = []
        for step in path {
            if case let .branch(direction, _, first, second) = cursor {
                ancestors.append((direction, step))
                cursor = step == 0 ? first : second
            } else {
                return nil
            }
        }
        guard case .leaf = cursor else { return nil }
        // Decide which axis matches the request.
        let wantHorizontalAxis: Bool = direction == .left || direction == .right
        let wantNegativeSide: Bool = direction == .left || direction == .up
        for i in (0..<ancestors.count).reversed() {
            let ancestor = ancestors[i]
            let isHorizontal = ancestor.direction == .vertical // .vertical divider → side-by-side
            if isHorizontal == wantHorizontalAxis {
                // We need to have come from the side opposite the target side.
                let cameFromHigh = ancestor.came == 1
                if (wantNegativeSide && cameFromHigh) || (!wantNegativeSide && !cameFromHigh) {
                    // Descend the OTHER side, picking the leaf closest to the
                    // shared edge: rightmost when going left, leftmost when going
                    // right, bottommost when going up, topmost when going down.
                    var descend = root
                    for step in path.prefix(i) {
                        guard case let .branch(_, _, first, second) = descend else { return nil }
                        descend = step == 0 ? first : second
                    }
                    guard case let .branch(_, _, first, second) = descend else { return nil }
                    descend = wantNegativeSide ? first : second
                    while case let .branch(branchDir, _, l, r) = descend {
                        if branchDir == ancestor.direction {
                            // Same axis — pick the leaf adjacent to the shared edge.
                            descend = wantNegativeSide ? r : l
                        } else {
                            // Different axis — descend into either side; pick
                            // the first leaf to keep behavior deterministic.
                            descend = l
                        }
                    }
                    return descend.paneID
                }
            }
        }
        return nil
    }

    func collectLeaves(in node: PaneNode) -> [PaneLeaf] {
        switch node {
        case let .leaf(leaf): return [leaf]
        case let .branch(_, _, first, second):
            return collectLeaves(in: first) + collectLeaves(in: second)
        }
    }

    func substituteLeaves(in node: PaneNode, iterator: inout IndexingIterator<[PaneLeaf]>) -> PaneNode {
        switch node {
        case .leaf:
            return iterator.next().map { .leaf($0) } ?? node
        case let .branch(direction, ratio, first, second):
            let f = substituteLeaves(in: first, iterator: &iterator)
            let s = substituteLeaves(in: second, iterator: &iterator)
            return .branch(direction: direction, ratio: ratio, first: f, second: s)
        }
    }

    func insertSplit(_ node: inout PaneNode, at target: PaneID, with newLeaf: PaneLeaf, direction: SplitDirection) {
        switch node {
        case let .leaf(leaf) where leaf.id == target:
            node = .branch(direction: direction, ratio: 0.5, first: .leaf(leaf), second: .leaf(newLeaf))
        case .branch(let dir, let ratio, var first, var second):
            insertSplit(&first, at: target, with: newLeaf, direction: direction)
            insertSplit(&second, at: target, with: newLeaf, direction: direction)
            node = .branch(direction: dir, ratio: ratio, first: first, second: second)
        default:
            break
        }
    }

    func build(layout: LayoutTemplate, leaves: [PaneLeaf]) -> PaneNode {
        switch layout {
        case .evenHorizontal:
            // panes side-by-side (vertical dividers between them)
            return buildEven(leaves: leaves, direction: .vertical)
        case .evenVertical:
            return buildEven(leaves: leaves, direction: .horizontal)
        case .mainHorizontal:
            // main pane on top (full width), the rest tiled side-by-side underneath
            guard let main = leaves.first else { return .leaf(PaneLeaf()) }
            let rest = Array(leaves.dropFirst())
            if rest.isEmpty { return .leaf(main) }
            let bottom = buildEven(leaves: rest, direction: .vertical)
            return .branch(direction: .horizontal, ratio: 0.5, first: .leaf(main), second: bottom)
        case .mainVertical:
            // main pane on left (full height), rest stacked top/bottom on right
            guard let main = leaves.first else { return .leaf(PaneLeaf()) }
            let rest = Array(leaves.dropFirst())
            if rest.isEmpty { return .leaf(main) }
            let right = buildEven(leaves: rest, direction: .horizontal)
            return .branch(direction: .vertical, ratio: 0.5, first: .leaf(main), second: right)
        case .tiled:
            return buildTiled(leaves: leaves)
        }
    }

    func buildEven(leaves: [PaneLeaf], direction: SplitDirection) -> PaneNode {
        guard !leaves.isEmpty else { return .leaf(PaneLeaf()) }
        if leaves.count == 1 { return .leaf(leaves[0]) }
        // Recursive equal split — produces a balanced binary tree whose visual
        // result is N evenly-sized panes along the chosen axis.
        let mid = leaves.count / 2
        let left = Array(leaves.prefix(mid))
        let right = Array(leaves.suffix(from: mid))
        let ratio = Double(left.count) / Double(leaves.count)
        return .branch(
            direction: direction,
            ratio: ratio,
            first: buildEven(leaves: left, direction: direction),
            second: buildEven(leaves: right, direction: direction)
        )
    }

    func buildTiled(leaves: [PaneLeaf]) -> PaneNode {
        // Grid that's roughly square. For N leaves, columns = ceil(sqrt(N)),
        // rows = ceil(N / columns). Last row may be shorter.
        guard !leaves.isEmpty else { return .leaf(PaneLeaf()) }
        if leaves.count == 1 { return .leaf(leaves[0]) }
        let columns = max(1, Int(Double(leaves.count).squareRoot().rounded(.up)))
        var rows: [[PaneLeaf]] = []
        var i = 0
        while i < leaves.count {
            let end = min(i + columns, leaves.count)
            rows.append(Array(leaves[i..<end]))
            i = end
        }
        let rowNodes = rows.map { buildEven(leaves: $0, direction: .vertical) }
        return buildEvenNodes(rowNodes, direction: .horizontal)
    }

    func buildEvenNodes(_ nodes: [PaneNode], direction: SplitDirection) -> PaneNode {
        guard !nodes.isEmpty else { return .leaf(PaneLeaf()) }
        if nodes.count == 1 { return nodes[0] }
        let mid = nodes.count / 2
        let left = Array(nodes.prefix(mid))
        let right = Array(nodes.suffix(from: mid))
        let ratio = Double(left.count) / Double(nodes.count)
        return .branch(
            direction: direction,
            ratio: ratio,
            first: buildEvenNodes(left, direction: direction),
            second: buildEvenNodes(right, direction: direction)
        )
    }
}
