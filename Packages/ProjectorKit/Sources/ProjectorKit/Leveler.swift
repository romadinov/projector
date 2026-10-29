import Foundation

/// Resource leveling: delays lower-priority tasks until no resource is overallocated.
public enum Leveler {
    public struct Result: Sendable {
        public var project: Project
        public var delayedTaskCount: Int
        /// Resources still overallocated because a single assignment exceeds their maximum units.
        public var unresolvedResourceIDs: Set<UUID>
    }

    public static func level(_ input: Project, maxIterations: Int = 5_000) -> Result {
        var project = input
        for i in project.tasks.indices { project.tasks[i].levelingDelay = 0 }
        let rowIndex = Dictionary(uniqueKeysWithValues: project.tasks.enumerated().map { ($1.id, $0) })
        let maxUnits = Dictionary(uniqueKeysWithValues: project.resources.map { ($0.id, $0.maxUnits) })
        let assignmentsByResource = Dictionary(grouping: project.assignments, by: \.resourceID)
        var unresolved: Set<UUID> = []
        // (resource, day) pairs that can't be fixed by delaying, so they're skipped on later passes.
        var skip: Set<String> = []
        let links = Dictionary(grouping: project.dependencies, by: \.predecessorID)

        for _ in 0..<maxIterations {
            let schedule = Scheduler.schedule(project)
            // Earliest overallocated day across all resources.
            var conflict: (resource: UUID, day: Int)?
            for (resourceID, load) in schedule.resourceLoads {
                for day in load.overallocatedDays where !skip.contains("\(resourceID)-\(day)") {
                    if conflict == nil || day < conflict!.day { conflict = (resourceID, day) }
                    break
                }
            }
            guard let (resourceID, day) = conflict else { break }

            // Tasks using this resource on that day, highest priority first:
            // already started, then least slack, then earliest row.
            let active = (assignmentsByResource[resourceID] ?? []).compactMap { a -> (Assignment, ScheduledTask)? in
                guard let t = schedule[a.taskID], !t.isSummary, t.duration > 0,
                      t.earlyStart < Double(day + 1) - 1e-9, t.earlyFinish > Double(day) + 1e-9 else { return nil }
                return (a, t)
            }.sorted { lhs, rhs in
                let lStarted = lhs.1.earlyStart < Double(day) - 1e-9
                let rStarted = rhs.1.earlyStart < Double(day) - 1e-9
                if lStarted != rStarted { return lStarted }
                if abs(lhs.1.totalSlack - rhs.1.totalSlack) > 1e-9 { return lhs.1.totalSlack < rhs.1.totalSlack }
                return (rowIndex[lhs.0.taskID] ?? 0) < (rowIndex[rhs.0.taskID] ?? 0)
            }

            // Delay the lowest-priority task that doesn't drive another conflicting task through a link;
            // delaying a driver would just drag the conflict along with it.
            let activeIDs = Set(active.map(\.0.taskID))
            var delayed = false
            for (assignment, scheduled) in active.reversed() where active.count > 1 {
                guard let i = rowIndex[assignment.taskID],
                      project.tasks[i].constraint != .mustStartOn,
                      successors(of: assignment.taskID, in: schedule.outline, links: links)
                        .isDisjoint(with: activeIDs.subtracting([assignment.taskID])) else { continue }
                project.tasks[i].levelingDelay += Double(day + 1) - scheduled.earlyStart
                delayed = true
                break
            }
            if !delayed {
                skip.insert("\(resourceID)-\(day)")
                unresolved.insert(resourceID)
            }
        }

        let count = project.tasks.filter { $0.levelingDelay > 1e-9 }.count
        let final = Scheduler.schedule(project)
        unresolved = unresolved.filter { final.resourceLoads[$0]?.isOverallocated ?? false }
        return Result(project: project, delayedTaskCount: count, unresolvedResourceIDs: unresolved)
    }

    /// Leaf tasks transitively driven by `id` (links on summaries apply to their leaves).
    static func successors(of id: UUID, in outline: Outline, links: [UUID: [Dependency]]) -> Set<UUID> {
        var result: Set<UUID> = []
        var stack = [id]
        while let current = stack.popLast() {
            for owner in [current] + outline.ancestors(of: current) {
                for d in links[owner] ?? [] {
                    for leaf in outline.leaves(of: d.successorID) where result.insert(leaf).inserted {
                        stack.append(leaf)
                    }
                }
            }
        }
        return result
    }

    public static func clear(_ project: inout Project) {
        for i in project.tasks.indices { project.tasks[i].levelingDelay = 0 }
    }
}
