import Foundation

public struct ScheduledTask: Sendable, Hashable {
    public var earlyStart: Double
    public var earlyFinish: Double
    public var lateStart: Double
    public var lateFinish: Double
    public var totalSlack: Double
    public var duration: Double
    public var isSummary: Bool
    public var isCritical: Bool
    public var start: Date
    public var finish: Date
    /// Assigned work in hours (rolled up for summaries).
    public var work: Double
    public var cost: Double
    public var percentComplete: Double
    /// Finishes after its own deadline or an ancestor's.
    public var missesDeadline: Bool = false

    public var isMilestone: Bool { !isSummary && duration == 0 }
}

public struct ResourceLoad: Sendable {
    /// Units allocated per working-day index (1.0 == one full-time person).
    public var daily: [Int: Double] = [:]
    public var peak: Double = 0
    public var overallocatedDays: [Int] = []
    public var work: Double = 0
    public var cost: Double = 0

    public var isOverallocated: Bool { !overallocatedDays.isEmpty }

    public init() {}
}

/// The result of scheduling a project: dates, slack, critical path and resource loading.
public struct Schedule {
    public let outline: Outline
    public let calendar: WorkCalendar
    public let tasks: [UUID: ScheduledTask]
    public let resourceLoads: [UUID: ResourceLoad]
    public let finishOffset: Double
    public let projectStart: Date
    public let projectFinish: Date
    /// Tasks that sit on a dependency loop; their links are partially ignored.
    public let cycleTaskIDs: Set<UUID>

    public subscript(id: UUID) -> ScheduledTask? { tasks[id] }

    public var totalWork: Double { tasks.values.filter { !$0.isSummary }.reduce(0) { $0 + $1.work } }
    public var totalCost: Double { tasks.values.filter { !$0.isSummary }.reduce(0) { $0 + $1.cost } }
    public var durationDays: Double { finishOffset }
    /// Leaf tasks that finish after a deadline.
    public var missedDeadlineCount: Int { tasks.values.filter { $0.missesDeadline && !$0.isSummary }.count }
}

public enum Scheduler {
    /// Critical path method: forward pass for early dates, backward pass for late dates and slack.
    public static func schedule(_ project: Project) -> Schedule {
        let outline = Outline(tasks: project.tasks)
        let calendar = WorkCalendar(settings: project.calendar, projectStart: project.startDate)
        let taskByID = Dictionary(uniqueKeysWithValues: project.tasks.map { ($0.id, $0) })

        // Links between a summary and its own subtree are meaningless; drop them.
        let deps = project.dependencies.filter { d in
            taskByID[d.predecessorID] != nil && taskByID[d.successorID] != nil
                && d.predecessorID != d.successorID
                && !outline.isAncestor(d.predecessorID, of: d.successorID)
                && !outline.isAncestor(d.successorID, of: d.predecessorID)
        }
        let depsBySuccessor = Dictionary(grouping: deps, by: \.successorID)
        let depsByPredecessor = Dictionary(grouping: deps, by: \.predecessorID)

        // Precedence graph: predecessor -> successor's leaves, child -> parent.
        var edges: [UUID: [UUID]] = [:]
        var inDegree: [UUID: Int] = Dictionary(uniqueKeysWithValues: project.tasks.map { ($0.id, 0) })
        func addEdge(_ from: UUID, _ to: UUID) {
            edges[from, default: []].append(to)
            inDegree[to, default: 0] += 1
        }
        for d in deps {
            for leaf in outline.leaves(of: d.successorID) { addEdge(d.predecessorID, leaf) }
        }
        for (child, parent) in outline.parent { addEdge(child, parent) }

        var order: [UUID] = []
        var queue = project.tasks.map(\.id).filter { inDegree[$0] == 0 }
        var head = 0
        while head < queue.count {
            let id = queue[head]; head += 1
            order.append(id)
            for next in edges[id] ?? [] {
                inDegree[next]! -= 1
                if inDegree[next] == 0 { queue.append(next) }
            }
        }
        var cycleIDs: Set<UUID> = []
        if order.count < project.tasks.count {
            let done = Set(order)
            // Schedule leftovers in outline order, children before parents.
            let leftovers = project.tasks.map(\.id).filter { !done.contains($0) }
            cycleIDs = Set(leftovers.filter { !outline.isSummary($0) })
            order += leftovers.filter { !outline.isSummary($0) }
            order += leftovers.filter { outline.isSummary($0) }
                .sorted { (outline.level[$0] ?? 0) > (outline.level[$1] ?? 0) }
        }

        // Forward pass.
        var es: [UUID: Double] = [:]
        var ef: [UUID: Double] = [:]
        for id in order {
            let task = taskByID[id]!
            if let kids = outline.children[id], !kids.isEmpty {
                es[id] = kids.compactMap { es[$0] }.min() ?? 0
                ef[id] = kids.compactMap { ef[$0] }.max() ?? 0
                continue
            }
            let duration = max(task.duration, 0)
            var start = 0.0
            for owner in [id] + outline.ancestors(of: id) {
                for d in depsBySuccessor[owner] ?? [] {
                    guard let pes = es[d.predecessorID], let pef = ef[d.predecessorID] else { continue }
                    switch d.type {
                    case .finishToStart: start = max(start, pef + d.lag)
                    case .startToStart: start = max(start, pes + d.lag)
                    case .finishToFinish: start = max(start, pef + d.lag - duration)
                    case .startToFinish: start = max(start, pes + d.lag - duration)
                    }
                }
                if let date = taskByID[owner]?.earliestStart {
                    start = max(start, Double(calendar.dayIndex(onOrAfter: date)))
                }
            }
            start = max(start, 0) + max(task.levelingDelay, 0)
            if task.constraint == .mustStartOn, let date = task.constraintDate {
                start = Double(calendar.dayIndex(onOrAfter: date))
            }
            es[id] = start
            ef[id] = start + duration
        }
        let finishOffset = ef.values.max() ?? 0

        // A deadline is the end of the last working day on or before its date.
        func deadlineOffset(_ id: UUID) -> Double? {
            ([id] + outline.ancestors(of: id)).compactMap { owner in
                taskByID[owner]?.finishBy.map { Double(calendar.dayIndex(onOrBefore: $0) + 1) }
            }.min()
        }

        // Backward pass over leaves, expanding summary links to their leaves.
        var ls: [UUID: Double] = [:]
        var lf: [UUID: Double] = [:]
        for id in order.reversed() where !outline.isSummary(id) {
            let duration = max(taskByID[id]!.duration, 0)
            var latest = min(finishOffset, deadlineOffset(id) ?? .infinity)
            for owner in [id] + outline.ancestors(of: id) {
                for d in depsByPredecessor[owner] ?? [] {
                    for leaf in outline.leaves(of: d.successorID) {
                        guard let sls = ls[leaf], let slf = lf[leaf] else { continue }
                        switch d.type {
                        case .finishToStart: latest = min(latest, sls - d.lag)
                        case .startToStart: latest = min(latest, sls - d.lag + duration)
                        case .finishToFinish: latest = min(latest, slf - d.lag)
                        case .startToFinish: latest = min(latest, slf - d.lag + duration)
                        }
                    }
                }
            }
            lf[id] = latest
            ls[id] = latest - duration
        }

        // Work and cost per leaf.
        let rates = Dictionary(uniqueKeysWithValues: project.resources.map { ($0.id, $0.standardRate) })
        var work: [UUID: Double] = [:]
        var cost: [UUID: Double] = [:]
        for a in project.assignments {
            guard let task = taskByID[a.taskID], !outline.isSummary(a.taskID), let rate = rates[a.resourceID] else { continue }
            let hours = max(task.duration, 0) * project.calendar.hoursPerDay * a.units
            work[a.taskID, default: 0] += hours
            cost[a.taskID, default: 0] += hours * rate
        }

        var result: [UUID: ScheduledTask] = [:]
        // Leaves first, then summaries deepest-first so roll-ups see their children.
        let leaves = project.tasks.filter { !outline.isSummary($0.id) }
        for task in leaves {
            let id = task.id
            let start = es[id] ?? 0, finish = ef[id] ?? 0
            let slack = (ls[id] ?? start) - start
            let startDate = calendar.startDate(offset: start)
            let finishDate = task.duration == 0
                ? (start > 0 && start == start.rounded() ? calendar.finishDate(offset: start) : startDate)
                : calendar.finishDate(offset: finish)
            result[id] = ScheduledTask(
                earlyStart: start, earlyFinish: finish,
                lateStart: ls[id] ?? start, lateFinish: lf[id] ?? finish,
                totalSlack: slack, duration: max(task.duration, 0), isSummary: false,
                isCritical: slack <= 1e-6,
                start: task.duration == 0 ? finishDate : startDate, finish: finishDate,
                work: work[id] ?? 0, cost: cost[id] ?? 0,
                percentComplete: min(max(task.percentComplete, 0), 100),
                missesDeadline: deadlineOffset(id).map { finish > $0 + 1e-6 } ?? false)
        }
        let summaries = project.tasks.map(\.id).filter(outline.isSummary)
            .sorted { (outline.level[$0] ?? 0) > (outline.level[$1] ?? 0) }
        for id in summaries {
            let kids = (outline.children[id] ?? []).compactMap { result[$0] }
            let start = es[id] ?? 0, finish = ef[id] ?? 0
            let totalDuration = kids.reduce(0) { $0 + $1.duration }
            let progress = totalDuration > 0
                ? kids.reduce(0) { $0 + $1.percentComplete * $1.duration } / totalDuration
                : (kids.isEmpty ? 0 : kids.reduce(0) { $0 + $1.percentComplete } / Double(kids.count))
            let slack = kids.map(\.totalSlack).min() ?? 0
            result[id] = ScheduledTask(
                earlyStart: start, earlyFinish: finish,
                lateStart: kids.map(\.lateStart).min() ?? start,
                lateFinish: kids.map(\.lateFinish).max() ?? finish,
                totalSlack: slack, duration: finish - start, isSummary: true,
                isCritical: kids.contains(where: \.isCritical),
                start: calendar.startDate(offset: start),
                finish: finish > start ? calendar.finishDate(offset: finish) : calendar.startDate(offset: start),
                work: kids.reduce(0) { $0 + $1.work }, cost: kids.reduce(0) { $0 + $1.cost },
                percentComplete: progress,
                missesDeadline: kids.contains(where: \.missesDeadline))
        }

        let loads = ResourceUsage.loads(project: project, outline: outline, tasks: result)
        return Schedule(
            outline: outline, calendar: calendar, tasks: result, resourceLoads: loads,
            finishOffset: finishOffset, projectStart: calendar.origin,
            projectFinish: finishOffset > 0 ? calendar.finishDate(offset: finishOffset) : calendar.origin,
            cycleTaskIDs: cycleIDs)
    }
}

public enum ResourceUsage {
    static func loads(project: Project, outline: Outline, tasks: [UUID: ScheduledTask]) -> [UUID: ResourceLoad] {
        var loads: [UUID: ResourceLoad] = Dictionary(uniqueKeysWithValues: project.resources.map { ($0.id, ResourceLoad()) })
        for a in project.assignments {
            guard loads[a.resourceID] != nil, let t = tasks[a.taskID], !t.isSummary, t.duration > 0 else { continue }
            let first = Int((t.earlyStart + 1e-9).rounded(.down))
            let last = WorkCalendar.finishDayIndex(t.earlyFinish)
            guard last >= first else { continue }
            for day in first...last {
                let overlap = min(t.earlyFinish, Double(day + 1)) - max(t.earlyStart, Double(day))
                if overlap > 1e-9 { loads[a.resourceID]!.daily[day, default: 0] += overlap * a.units }
            }
            loads[a.resourceID]!.work += t.duration * project.calendar.hoursPerDay * a.units
            loads[a.resourceID]!.cost += t.duration * project.calendar.hoursPerDay * a.units
                * (project.resource(a.resourceID)?.standardRate ?? 0)
        }
        for resource in project.resources {
            guard var load = loads[resource.id] else { continue }
            load.peak = load.daily.values.max() ?? 0
            load.overallocatedDays = load.daily.filter { $0.value > resource.maxUnits + 1e-6 }.map(\.key).sorted()
            loads[resource.id] = load
        }
        return loads
    }
}
