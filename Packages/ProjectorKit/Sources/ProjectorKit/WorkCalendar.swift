import Foundation

/// Maps working-day offsets (the scheduler's unit of time) to calendar dates.
///
/// Day index 0 is the first working day on or after the project start. An offset of 2.5
/// means "halfway through the third working day".
public final class WorkCalendar {
    public let settings: CalendarSettings
    public let calendar: Calendar
    public let origin: Date

    private let holidays: Set<Date>
    private var days: [Date]
    /// Calendar days between `origin` and `days[i]`.
    private var calendarOffsets: [Int]

    private static let searchLimit = 100_000

    public init(settings: CalendarSettings, projectStart: Date, calendar: Calendar = .current) {
        self.settings = settings
        self.calendar = calendar
        self.holidays = Set(settings.holidays.map { calendar.startOfDay(for: $0) })
        var first = calendar.startOfDay(for: projectStart)
        var steps = 0
        let isWorking: (Date) -> Bool = { [holidays] date in
            settings.workingWeekdays.isEmpty
                || (settings.workingWeekdays.contains(calendar.component(.weekday, from: date))
                    && !holidays.contains(date))
        }
        while !isWorking(first), steps < 366 {
            first = calendar.date(byAdding: .day, value: 1, to: first)!
            steps += 1
        }
        self.origin = first
        self.days = [first]
        self.calendarOffsets = [0]
    }

    public func isWorkingDay(_ date: Date) -> Bool {
        if settings.workingWeekdays.isEmpty { return true }
        let day = calendar.startOfDay(for: date)
        return settings.workingWeekdays.contains(calendar.component(.weekday, from: day))
            && !holidays.contains(day)
    }

    private func extend(through index: Int) {
        while days.count <= index, days.count < Self.searchLimit {
            var next = days[days.count - 1]
            var offset = calendarOffsets[calendarOffsets.count - 1]
            repeat {
                next = calendar.date(byAdding: .day, value: 1, to: next)!
                offset += 1
            } while !isWorkingDay(next)
            days.append(next)
            calendarOffsets.append(offset)
        }
    }

    /// The date of working day `index` (clamped at 0).
    public func date(forDay index: Int) -> Date {
        let i = min(max(index, 0), Self.searchLimit - 1)
        extend(through: i)
        return days[min(i, days.count - 1)]
    }

    /// Calendar days from `origin` to working day `index`.
    public func calendarOffset(forDay index: Int) -> Int {
        let i = min(max(index, 0), Self.searchLimit - 1)
        extend(through: i)
        return calendarOffsets[min(i, calendarOffsets.count - 1)]
    }

    /// Index of the first working day on or after `date`.
    public func dayIndex(onOrAfter date: Date) -> Int {
        let target = calendar.startOfDay(for: date)
        if target <= origin { return 0 }
        while days[days.count - 1] < target, days.count < Self.searchLimit {
            extend(through: days.count * 2)
        }
        var low = 0, high = days.count - 1
        while low < high {
            let mid = (low + high) / 2
            if days[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Index of the last working day on or before `date`.
    public func dayIndex(onOrBefore date: Date) -> Int {
        let index = dayIndex(onOrAfter: date)
        let target = calendar.startOfDay(for: date)
        return self.date(forDay: index) > target ? max(index - 1, 0) : index
    }

    /// The working day on which an activity starting at `offset` begins.
    public func startDate(offset: Double) -> Date {
        date(forDay: Int((offset + 1e-9).rounded(.down)))
    }

    /// The working day on which an activity ending at `offset` finishes.
    public func finishDate(offset: Double) -> Date {
        date(forDay: Self.finishDayIndex(offset))
    }

    public static func finishDayIndex(_ offset: Double) -> Int {
        max(Int((offset - 1e-9).rounded(.up)) - 1, 0)
    }

    /// Whole calendar days between two dates (`to - from`).
    public func calendarDays(from: Date, to: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }
}
