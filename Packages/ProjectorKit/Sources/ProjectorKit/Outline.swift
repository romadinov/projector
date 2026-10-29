import Foundation

/// The work breakdown structure derived from the ordered task list and outline levels.
public struct Outline: Sendable {
    public let order: [UUID]
    public let rowIndex: [UUID: Int]
    public let parent: [UUID: UUID]
    public let children: [UUID: [UUID]]
    public let wbs: [UUID: String]
    public let level: [UUID: Int]

    public init(tasks: [ProjectTask]) {
        var parent: [UUID: UUID] = [:]
        var children: [UUID: [UUID]] = [:]
        var wbs: [UUID: String] = [:]
        var level: [UUID: Int] = [:]
        var rowIndex: [UUID: Int] = [:]
        var stack: [(level: Int, id: UUID)] = []
        var topCount = 0

        for (i, task) in tasks.enumerated() {
            rowIndex[task.id] = i
            while let last = stack.last, last.level >= task.outlineLevel { stack.removeLast() }
            if let p = stack.last {
                parent[task.id] = p.id
                children[p.id, default: []].append(task.id)
                wbs[task.id] = "\(wbs[p.id]!).\(children[p.id]!.count)"
                level[task.id] = level[p.id]! + 1
            } else {
                topCount += 1
                wbs[task.id] = "\(topCount)"
                level[task.id] = 1
            }
            stack.append((task.outlineLevel, task.id))
        }
        self.order = tasks.map(\.id)
        self.rowIndex = rowIndex
        self.parent = parent
        self.children = children
        self.wbs = wbs
        self.level = level
    }

    public func isSummary(_ id: UUID) -> Bool { !(children[id]?.isEmpty ?? true) }

    public func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var current = parent[id]
        while let p = current {
            result.append(p)
            current = parent[p]
        }
        return result
    }

    public func isAncestor(_ ancestor: UUID, of id: UUID) -> Bool {
        ancestors(of: id).contains(ancestor)
    }

    public func descendants(of id: UUID) -> [UUID] {
        (children[id] ?? []).flatMap { [$0] + descendants(of: $0) }
    }

    /// Leaf tasks under `id`, or `[id]` when it is itself a leaf.
    public func leaves(of id: UUID) -> [UUID] {
        guard let kids = children[id], !kids.isEmpty else { return [id] }
        return kids.flatMap { leaves(of: $0) }
    }

    /// Row ids visible when the summaries in `collapsed` hide their subtrees.
    public func visibleRows(collapsed: Set<UUID>) -> [UUID] {
        guard !collapsed.isEmpty else { return order }
        return order.filter { id in !ancestors(of: id).contains(where: collapsed.contains) }
    }
}
