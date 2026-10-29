import Foundation

/// Calendar buckets for timephased (spreadsheet-style) views.
public enum Timescale: String, CaseIterable, Sendable, Identifiable {
    case day, week, month

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .day: "Days"
        case .week: "Weeks"
        case .month: "Months"
        }
    }
}

public struct TimePeriod: Sendable, Hashable {
    public let start: Date
    /// Exclusive.
    public let end: Date
    /// Working-day indices inside the period, or nil if it has none (a weekend day, a holiday week).
    public let days: ClosedRange<Int>?

    public var workingDayCount: Int { days?.count ?? 0 }
}

extension Schedule {
    /// Periods covering the whole project, aligned to the start of each day, week or month.
    public func periods(_ timescale: Timescale) -> [TimePeriod] {
        let cal = calendar.calendar
        let component: Calendar.Component = switch timescale {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        var start = cal.dateInterval(of: component, for: projectStart)?.start ?? projectStart
        var result: [TimePeriod] = []
        while start <= projectFinish, result.count < 5_000 {
            let end = cal.dateInterval(of: component, for: start)?.end
                ?? cal.date(byAdding: .day, value: 1, to: start)!
            let first = calendar.dayIndex(onOrAfter: start)
            let last = calendar.dayIndex(onOrBefore: cal.date(byAdding: .day, value: -1, to: end)!)
            let hasDays = first <= last && calendar.date(forDay: first) < end && calendar.date(forDay: last) >= start
            result.append(TimePeriod(start: start, end: end, days: hasDays ? first...last : nil))
            start = end
        }
        return result
    }

    /// Hours of `assignment` worked in `period`.
    public func work(of assignment: Assignment, in period: TimePeriod) -> Double {
        guard let days = period.days, let t = tasks[assignment.taskID], !t.isSummary, t.duration > 0 else { return 0 }
        let first = max(days.lowerBound, Int((t.earlyStart + 1e-9).rounded(.down)))
        let last = min(days.upperBound, WorkCalendar.finishDayIndex(t.earlyFinish))
        guard first <= last else { return 0 }
        var units = 0.0
        for day in first...last {
            units += max(min(t.earlyFinish, Double(day + 1)) - max(t.earlyStart, Double(day)), 0)
        }
        return units * assignment.units * calendar.settings.hoursPerDay
    }

    /// Total hours booked on a resource in `period`.
    public func work(ofResource id: UUID, in period: TimePeriod) -> Double {
        guard let days = period.days, let load = resourceLoads[id] else { return 0 }
        return days.reduce(0) { $0 + (load.daily[$1] ?? 0) } * calendar.settings.hoursPerDay
    }

    /// Hours a resource can work in `period` at its maximum units.
    public func capacity(of resource: Resource, in period: TimePeriod) -> Double {
        Double(period.workingDayCount) * resource.maxUnits * calendar.settings.hoursPerDay
    }

    /// True if the resource is over its maximum units on any day of `period` (MS Project's rule).
    public func isOverallocated(_ resource: Resource, in period: TimePeriod) -> Bool {
        guard let days = period.days, let load = resourceLoads[resource.id] else { return false }
        return load.overallocatedDays.contains { days.contains($0) }
    }
}
