import Foundation

public enum EditError: Error, Equatable, LocalizedError {
    case invalidSyntax
    case unknownRow(Int)
    case selfReference
    case summaryLink
    case circularDependency

    public var errorDescription: String? {
        switch self {
        case .invalidSyntax: "That entry couldn't be understood."
        case .unknownRow(let row): "There is no task with ID \(row)."
        case .selfReference: "A task can't depend on itself."
        case .summaryLink: "A summary task can't be linked to its own subtasks."
        case .circularDependency: "That link would create a circular dependency."
        }
    }
}

/// Outline and link editing, mirroring MS Project's Task ribbon.
extension Project {
    /// Index just past `index`'s subtree.
    public func subtreeEnd(_ index: Int) -> Int {
        let level = tasks[index].outlineLevel
        var end = index + 1
        while end < tasks.count, tasks[end].outlineLevel > level { end += 1 }
        return end
    }

    /// Inserts a task below `afterID`'s row (or at the end) at the same outline level.
    @discardableResult
    public mutating func insertTask(named name: String, duration: Double = 1, after afterID: UUID?) -> UUID {
        var task = ProjectTask(name: name, duration: duration)
        var position = tasks.count
        if let afterID, let i = index(of: afterID) {
            let outline = Outline(tasks: tasks)
            // Below an expanded summary, a new row becomes its first child, as in MS Project.
            if outline.isSummary(afterID) {
                task.outlineLevel = tasks[i].outlineLevel + 1
            } else {
                task.outlineLevel = tasks[i].outlineLevel
            }
            position = i + 1
        } else if let last = tasks.last {
            task.outlineLevel = last.outlineLevel
        }
        tasks.insert(task, at: position)
        normalizeOutline()
        return task.id
    }

    /// Topmost ids of a selection (skips rows whose ancestor is also selected), in row order.
    func topmost(_ ids: Set<UUID>) -> [Int] {
        let outline = Outline(tasks: tasks)
        return tasks.indices.filter { i in
            ids.contains(tasks[i].id) && !outline.ancestors(of: tasks[i].id).contains(where: ids.contains)
        }
    }

    public mutating func indent(_ ids: Set<UUID>) {
        for i in topmost(ids) where i > 0 && tasks[i].outlineLevel <= tasks[i - 1].outlineLevel {
            for j in i..<subtreeEnd(i) { tasks[j].outlineLevel += 1 }
        }
        normalizeOutline()
        removeInvalidLinks()
    }

    public mutating func outdent(_ ids: Set<UUID>) {
        for i in topmost(ids).reversed() where tasks[i].outlineLevel > 1 {
            for j in i..<subtreeEnd(i) { tasks[j].outlineLevel -= 1 }
        }
        normalizeOutline()
        removeInvalidLinks()
    }

    public mutating func moveUp(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let level = tasks[i].outlineLevel
        var j = i - 1
        while j >= 0, tasks[j].outlineLevel > level { j -= 1 }
        guard j >= 0, tasks[j].outlineLevel == level else { return }
        let block = Array(tasks[i..<subtreeEnd(i)])
        tasks.removeSubrange(i..<subtreeEnd(i))
        tasks.insert(contentsOf: block, at: j)
    }

    public mutating func moveDown(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let end = subtreeEnd(i)
        guard end < tasks.count, tasks[end].outlineLevel == tasks[i].outlineLevel else { return }
        let nextID = tasks[end].id
        moveUp(nextID)
    }

    /// Deletes tasks with their subtasks, links and assignments.
    public mutating func deleteTasks(_ ids: Set<UUID>) {
        var doomed = Set<UUID>()
        for i in topmost(ids) { doomed.formUnion(tasks[i..<subtreeEnd(i)].map(\.id)) }
        tasks.removeAll { doomed.contains($0.id) }
        dependencies.removeAll { doomed.contains($0.predecessorID) || doomed.contains($0.successorID) }
        assignments.removeAll { doomed.contains($0.taskID) }
        normalizeOutline()
    }

    /// First task at level 1; no task more than one level deeper than the row above.
    public mutating func normalizeOutline() {
        var previous = 0
        for i in tasks.indices {
            tasks[i].outlineLevel = min(max(tasks[i].outlineLevel, 1), previous + 1)
            previous = tasks[i].outlineLevel
        }
    }

    mutating func removeInvalidLinks() {
        let outline = Outline(tasks: tasks)
        dependencies.removeAll {
            outline.isAncestor($0.predecessorID, of: $0.successorID) || outline.isAncestor($0.successorID, of: $0.predecessorID)
        }
    }

    // MARK: Links

    /// Links the selected tasks finish-to-start in row order.
    public mutating func linkTasks(_ ids: Set<UUID>) throws {
        let rows = tasks.indices.filter { ids.contains(tasks[$0].id) }.map { tasks[$0].id }
        guard rows.count > 1 else { return }
        var candidate = self
        for (pred, succ) in zip(rows, rows.dropFirst())
        where !candidate.dependencies.contains(where: { $0.predecessorID == pred && $0.successorID == succ }) {
            try candidate.addDependency(Dependency(predecessorID: pred, successorID: succ))
        }
        self = candidate
    }

    /// Removes every link among the selected tasks, or all of their links if only one is selected.
    public mutating func unlinkTasks(_ ids: Set<UUID>) {
        if ids.count == 1 {
            dependencies.removeAll { ids.contains($0.predecessorID) || ids.contains($0.successorID) }
        } else {
            dependencies.removeAll { ids.contains($0.predecessorID) && ids.contains($0.successorID) }
        }
    }

    public mutating func addDependency(_ dependency: Dependency) throws {
        guard dependency.predecessorID != dependency.successorID else { throw EditError.selfReference }
        let outline = Outline(tasks: tasks)
        if outline.isAncestor(dependency.predecessorID, of: dependency.successorID)
            || outline.isAncestor(dependency.successorID, of: dependency.predecessorID) {
            throw EditError.summaryLink
        }
        var candidate = self
        candidate.dependencies.removeAll {
            $0.predecessorID == dependency.predecessorID && $0.successorID == dependency.successorID
        }
        candidate.dependencies.append(dependency)
        guard Scheduler.schedule(candidate).cycleTaskIDs.isEmpty else { throw EditError.circularDependency }
        self = candidate
    }

    /// Replaces a task's predecessors from "3FS+2d, 5" notation.
    public mutating func setPredecessors(of taskID: UUID, text: String) throws {
        guard let specs = Notation.parsePredecessors(text, settings: calendar) else { throw EditError.invalidSyntax }
        var candidate = self
        candidate.dependencies.removeAll { $0.successorID == taskID }
        for spec in specs {
            guard spec.row >= 1, spec.row <= tasks.count else { throw EditError.unknownRow(spec.row) }
            try candidate.addDependency(Dependency(
                predecessorID: tasks[spec.row - 1].id, successorID: taskID, type: spec.type, lag: spec.lag))
        }
        self = candidate
    }

    // MARK: Assignments

    /// Replaces a task's assignments from "Ann, Bob[50%]" notation, creating unknown resources.
    public mutating func setResources(of taskID: UUID, text: String) throws {
        guard let specs = Notation.parseResources(text) else { throw EditError.invalidSyntax }
        assignments.removeAll { $0.taskID == taskID }
        for spec in specs {
            let resourceID: UUID
            if let existing = resources.first(where: {
                $0.name.caseInsensitiveCompare(spec.name) == .orderedSame
                    || $0.initials.caseInsensitiveCompare(spec.name) == .orderedSame
            }) {
                resourceID = existing.id
            } else {
                let resource = Resource(name: spec.name)
                resources.append(resource)
                resourceID = resource.id
            }
            assignments.removeAll { $0.taskID == taskID && $0.resourceID == resourceID }
            assignments.append(Assignment(taskID: taskID, resourceID: resourceID, units: spec.units))
        }
    }

    public mutating func deleteResources(_ ids: Set<UUID>) {
        resources.removeAll { ids.contains($0.id) }
        assignments.removeAll { ids.contains($0.resourceID) }
    }

    // MARK: Baseline

    public mutating func setBaseline(using schedule: Schedule) {
        for i in tasks.indices {
            guard let s = schedule[tasks[i].id] else { continue }
            tasks[i].baselineStart = s.start
            tasks[i].baselineFinish = s.finish
        }
    }

    public mutating func clearBaseline() {
        for i in tasks.indices {
            tasks[i].baselineStart = nil
            tasks[i].baselineFinish = nil
        }
    }
}
