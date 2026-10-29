import SwiftUI
import ProjectorKit

/// Maps calendar dates and scheduler offsets to x positions on a timeline.
struct TimelineScale {
    let workCalendar: WorkCalendar
    let origin: Date
    /// Calendar days from the work calendar's origin back to the timeline's origin (≤ 0).
    let originDelta: Int
    let dayCount: Int
    let pixelsPerDay: CGFloat

    var calendar: Calendar { workCalendar.calendar }
    var width: CGFloat { CGFloat(dayCount) * pixelsPerDay }

    init(schedule: Schedule, pixelsPerDay: CGFloat, minimumWidth: CGFloat = 1200) {
        let cal = schedule.calendar.calendar
        self.workCalendar = schedule.calendar
        self.pixelsPerDay = pixelsPerDay
        // Start a week before the project, aligned to the start of that week.
        let before = cal.date(byAdding: .day, value: -7, to: schedule.projectStart)!
        let weekStart = cal.dateInterval(of: .weekOfYear, for: before)?.start ?? before
        self.origin = cal.startOfDay(for: weekStart)
        self.originDelta = schedule.calendar.calendarDays(from: schedule.calendar.origin, to: origin)
        let finish = max(schedule.projectFinish, .now)
        let span = schedule.calendar.calendarDays(from: origin, to: finish) + 60
        self.dayCount = max(span, Int(minimumWidth / pixelsPerDay) + 1)
    }

    func x(for date: Date) -> CGFloat {
        CGFloat(workCalendar.calendarDays(from: origin, to: date)) * pixelsPerDay
    }

    func x(forDay index: Int) -> CGFloat {
        CGFloat(workCalendar.calendarOffset(forDay: index) - originDelta) * pixelsPerDay
    }

    /// Left edge of an activity starting at scheduler `offset`.
    func startX(_ offset: Double) -> CGFloat {
        let day = Int((offset + 1e-9).rounded(.down))
        return x(forDay: day) + CGFloat(offset - Double(day)) * pixelsPerDay
    }

    /// Right edge of an activity finishing at scheduler `offset`.
    func finishX(_ offset: Double) -> CGFloat {
        let day = WorkCalendar.finishDayIndex(offset)
        return x(forDay: day) + CGFloat(min(max(offset - Double(day), 0), 1)) * pixelsPerDay
    }

    /// Where a milestone at `offset` sits: the end of the previous working day, as in MS Project.
    func milestoneX(_ offset: Double) -> CGFloat {
        offset > 0 && offset == offset.rounded() ? finishX(offset) : startX(offset)
    }

    func date(atX x: CGFloat) -> Date {
        calendar.date(byAdding: .day, value: Int((x / pixelsPerDay).rounded(.down)), to: origin)!
    }

    /// Shades non-working days and draws the today line across `rect`.
    func drawCalendarBackground(in context: inout GraphicsContext, rect: CGRect) {
        if pixelsPerDay >= 4 {
            let firstDay = max(Int((rect.minX / pixelsPerDay).rounded(.down)), 0)
            let lastDay = min(Int((rect.maxX / pixelsPerDay).rounded(.up)), dayCount)
            if firstDay <= lastDay {
                var shade = Path()
                for day in firstDay...lastDay {
                    let date = calendar.date(byAdding: .day, value: day, to: origin)!
                    if !workCalendar.isWorkingDay(date) {
                        shade.addRect(CGRect(x: CGFloat(day) * pixelsPerDay, y: rect.minY, width: pixelsPerDay, height: rect.height))
                    }
                }
                context.fill(shade, with: .color(.secondary.opacity(0.08)))
            }
        }
        let todayX = x(for: .now) + pixelsPerDay / 2
        if todayX >= rect.minX, todayX <= rect.maxX {
            var line = Path()
            line.move(to: CGPoint(x: todayX, y: rect.minY))
            line.addLine(to: CGPoint(x: todayX, y: rect.maxY))
            context.stroke(line, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

/// The two-tier date header above a timeline (e.g. weeks over days).
struct TimelineHeader: View {
    let scale: TimelineScale
    let offsetX: CGFloat

    enum Unit { case day, week, month, quarter, year }

    var body: some View {
        Canvas { context, size in
            let tiers = Self.tiers(for: scale.pixelsPerDay)
            let half = size.height / 2
            draw(tiers.top, in: &context, y: 0, height: half, width: size.width, bold: true)
            draw(tiers.bottom, in: &context, y: half, height: half, width: size.width, bold: false)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: half))
            line.addLine(to: CGPoint(x: size.width, y: half))
            line.move(to: CGPoint(x: 0, y: size.height - 0.5))
            line.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(line, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
        }
        .background(.bar)
    }

    static func tiers(for ppd: CGFloat) -> (top: Unit, bottom: Unit) {
        switch ppd {
        case 18...: (.week, .day)
        case 5..<18: (.month, .week)
        case 1.5..<5: (.year, .month)
        default: (.year, .quarter)
        }
    }

    private func label(_ date: Date, unit: Unit, top: Bool) -> String {
        let cal = scale.calendar
        switch unit {
        case .day:
            return scale.pixelsPerDay >= 30
                ? date.formatted(.dateTime.weekday(.narrow).day())
                : date.formatted(.dateTime.weekday(.narrow))
        case .week:
            return top ? date.formatted(.dateTime.day().month(.abbreviated).year()) : date.formatted(.dateTime.day())
        case .month:
            return top ? date.formatted(.dateTime.month(.wide).year()) : date.formatted(.dateTime.month(.abbreviated))
        case .quarter:
            return "Q\((cal.component(.month, from: date) - 1) / 3 + 1)"
        case .year:
            return date.formatted(.dateTime.year())
        }
    }

    private func start(of unit: Unit, containing date: Date) -> Date {
        let cal = scale.calendar
        switch unit {
        case .day: return cal.startOfDay(for: date)
        case .week: return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        case .month: return cal.dateInterval(of: .month, for: date)?.start ?? date
        case .quarter:
            let month = cal.dateInterval(of: .month, for: date)?.start ?? date
            let m = cal.component(.month, from: month)
            return cal.date(byAdding: .month, value: -((m - 1) % 3), to: month)!
        case .year: return cal.dateInterval(of: .year, for: date)?.start ?? date
        }
    }

    private func next(_ date: Date, unit: Unit) -> Date {
        let cal = scale.calendar
        switch unit {
        case .day: return cal.date(byAdding: .day, value: 1, to: date)!
        case .week: return cal.date(byAdding: .day, value: 7, to: date)!
        case .month: return cal.date(byAdding: .month, value: 1, to: date)!
        case .quarter: return cal.date(byAdding: .month, value: 3, to: date)!
        case .year: return cal.date(byAdding: .year, value: 1, to: date)!
        }
    }

    private func draw(_ unit: Unit, in context: inout GraphicsContext, y: CGFloat, height: CGFloat, width: CGFloat, bold: Bool) {
        var date = start(of: unit, containing: scale.date(atX: max(offsetX, 0)))
        var separators = Path()
        var guardCount = 0
        while guardCount < 2000 {
            guardCount += 1
            let x0 = scale.x(for: date) - offsetX
            if x0 > width { break }
            let following = next(date, unit: unit)
            let x1 = scale.x(for: following) - offsetX
            separators.move(to: CGPoint(x: x0, y: y))
            separators.addLine(to: CGPoint(x: x0, y: y + height))
            let text = Text(label(date, unit: unit, top: bold))
                .font(.system(size: 10.5, weight: bold ? .semibold : .regular))
                .foregroundStyle(.secondary)
            let resolved = context.resolve(text)
            let textSize = resolved.measure(in: CGSize(width: 400, height: height))
            let span = x1 - x0
            if textSize.width + 6 <= span {
                // Keep the label of a partially scrolled cell visible.
                let labelX = unit == .day ? x0 + (span - textSize.width) / 2 : min(max(x0 + 4, 4), x1 - textSize.width - 4)
                context.draw(resolved, at: CGPoint(x: labelX, y: y + height / 2), anchor: .leading)
            }
            date = following
        }
        context.stroke(separators, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
    }
}
