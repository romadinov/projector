import Foundation

/// Microsoft Project XML (MSPDI). Elements are written in schema order, which MS Project expects.
///
/// Link types: 0 FF, 1 FS, 2 SF, 3 SS. Lags and durations are in tenths of a minute and ISO durations
/// of working time. Constraint types: 0 ASAP, 2 MSO, 3 MFO, 4 SNET, 5 SNLT, 6 FNET, 7 FNLT.
public enum MSProjectXML {
    static let namespace = "http://schemas.microsoft.com/project"

    // MARK: Export

    public static func export(_ project: Project) -> Data {
        let schedule = Scheduler.schedule(project)
        let outline = schedule.outline
        let cal = schedule.calendar
        let day = WorkingDay(hours: project.calendar.hoursPerDay)
        let minutesPerDay = Int((project.calendar.hoursPerDay * 60).rounded())
        let stamp = { (date: Date) in DateText.format(date, seconds: true) }
        let uid = Dictionary(uniqueKeysWithValues: project.tasks.enumerated().map { ($1.id, $0 + 1) })
        let resourceUID = Dictionary(uniqueKeysWithValues: project.resources.enumerated().map { ($1.id, $0 + 1) })

        var x = MarkupWriter()
        x.open("Project", attributes: "xmlns=\"\(namespace)\"")
        x.element("SaveVersion", 14)
        x.element("Name", project.name)
        x.element("Title", project.name)
        x.element("Manager", project.manager.nonEmpty)
        x.element("ScheduleFromStart", 1)
        x.element("StartDate", stamp(day.start(0, on: cal)))
        x.element("FinishDate", stamp(day.finish(schedule.finishOffset, on: cal)))
        x.element("CurrencyCode", project.currencyCode)
        x.element("CalendarUID", 1)
        x.element("DefaultStartTime", clockText(day.periods[0].from))
        x.element("DefaultFinishTime", clockText(day.endHour))
        x.element("MinutesPerDay", minutesPerDay)
        x.element("MinutesPerWeek", minutesPerDay * project.calendar.workingWeekdays.count)
        x.element("DaysPerMonth", 20)

        x.open("Calendars")
        x.open("Calendar")
        x.element("UID", 1)
        x.element("Name", "Standard")
        x.element("IsBaseCalendar", 1)
        x.element("BaseCalendarUID", -1)
        x.open("WeekDays")
        for weekday in 1...7 {
            x.open("WeekDay")
            x.element("DayType", weekday)
            let working = project.calendar.workingWeekdays.contains(weekday)
            x.element("DayWorking", working ? 1 : 0)
            if working {
                x.open("WorkingTimes")
                for p in day.periods {
                    x.open("WorkingTime")
                    x.element("FromTime", clockText(p.from))
                    x.element("ToTime", clockText(p.to))
                    x.close("WorkingTime")
                }
                x.close("WorkingTimes")
            }
            x.close("WeekDay")
        }
        x.close("WeekDays")
        if !project.calendar.holidays.isEmpty {
            x.open("Exceptions")
            for holiday in project.calendar.holidays.sorted() {
                let start = cal.calendar.startOfDay(for: holiday)
                x.open("Exception")
                x.element("EnteredByOccurrences", 0)
                x.open("TimePeriod")
                x.element("FromDate", stamp(start))
                x.element("ToDate", stamp(cal.calendar.date(byAdding: .minute, value: 23 * 60 + 59, to: start)!))
                x.close("TimePeriod")
                x.element("Occurrences", 1)
                x.element("Name", "Holiday")
                x.element("Type", 1)
                x.element("DayWorking", 0)
                x.close("Exception")
            }
            x.close("Exceptions")
        }
        x.close("Calendar")
        // MS Project gives every work resource its own calendar based on the project's.
        for (i, resource) in project.resources.enumerated() {
            x.open("Calendar")
            x.element("UID", i + 2)
            x.element("Name", resource.name)
            x.element("IsBaseCalendar", 0)
            x.element("BaseCalendarUID", 1)
            x.close("Calendar")
        }
        x.close("Calendars")

        let predecessors = Dictionary(grouping: project.dependencies, by: \.successorID)
        x.open("Tasks")
        for (i, task) in project.tasks.enumerated() {
            guard let s = schedule[task.id] else { continue }
            let summary = outline.isSummary(task.id)
            let start = day.start(s.earlyStart, on: cal)
            let finish = s.duration == 0 && !summary ? day.finish(s.earlyStart, on: cal) : day.finish(s.earlyFinish, on: cal)
            x.open("Task")
            x.element("UID", i + 1)
            x.element("ID", i + 1)
            x.element("Name", task.name)
            x.element("Active", 1)
            x.element("Manual", 0)
            x.element("Type", 1) // fixed duration: assigning people doesn't change the length
            x.element("IsNull", 0)
            x.element("WBS", outline.wbs[task.id])
            x.element("OutlineNumber", outline.wbs[task.id])
            x.element("OutlineLevel", outline.level[task.id] ?? 1)
            x.element("Priority", 500)
            x.element("Start", stamp(s.duration == 0 && !summary ? finish : start))
            x.element("Finish", stamp(finish))
            x.element("Duration", isoDuration(hours: s.duration * project.calendar.hoursPerDay))
            x.element("DurationFormat", 7)
            x.element("EffortDriven", 0)
            x.element("Milestone", !summary && task.duration == 0 ? 1 : 0)
            x.element("Summary", summary ? 1 : 0)
            x.element("Critical", s.isCritical ? 1 : 0)
            x.element("PercentComplete", Int(s.percentComplete.rounded()))
            if task.constraint == .mustStartOn, let date = task.constraintDate {
                x.element("ConstraintType", 2)
                x.element("ConstraintDate", stamp(day.at(date, hour: day.periods[0].from, cal.calendar)))
            } else if let date = task.earliestStart {
                x.element("ConstraintType", 4)
                x.element("ConstraintDate", stamp(day.at(date, hour: day.periods[0].from, cal.calendar)))
            } else {
                x.element("ConstraintType", 0)
            }
            if let deadline = task.finishBy {
                x.element("Deadline", stamp(day.at(deadline, hour: day.endHour, cal.calendar)))
            }
            if task.levelingDelay > 0 {
                x.element("LevelingDelay", Int((task.levelingDelay * Double(minutesPerDay) * 10).rounded()))
                x.element("LevelingDelayFormat", 7)
            }
            x.element("Notes", task.notes.nonEmpty)
            for d in predecessors[task.id] ?? [] {
                guard let p = uid[d.predecessorID] else { continue }
                x.open("PredecessorLink")
                x.element("PredecessorUID", p)
                x.element("Type", linkCode(d.type))
                x.element("CrossProject", 0)
                x.element("LinkLag", Int((d.lag * Double(minutesPerDay) * 10).rounded()))
                x.element("LagFormat", 7)
                x.close("PredecessorLink")
            }
            if let bs = task.baselineStart, let bf = task.baselineFinish {
                x.open("Baseline")
                x.element("Number", 0)
                x.element("Start", stamp(day.at(bs, hour: day.periods[0].from, cal.calendar)))
                x.element("Finish", stamp(day.at(bf, hour: day.endHour, cal.calendar)))
                x.close("Baseline")
            }
            x.close("Task")
        }
        x.close("Tasks")

        x.open("Resources")
        for (i, r) in project.resources.enumerated() {
            x.open("Resource")
            x.element("UID", i + 1)
            x.element("ID", i + 1)
            x.element("Name", r.name)
            x.element("Type", 1)
            x.element("IsNull", 0)
            x.element("Initials", r.initials.nonEmpty)
            x.element("Group", r.group.nonEmpty)
            x.element("EmailAddress", r.email.nonEmpty)
            x.element("MaxUnits", plainNumber(r.maxUnits))
            x.element("StandardRate", plainNumber(r.standardRate))
            x.element("StandardRateFormat", 2)
            x.element("CalendarUID", i + 2)
            x.close("Resource")
        }
        x.close("Resources")

        x.open("Assignments")
        var assignmentUID = 0
        for a in project.assignments {
            guard let t = uid[a.taskID], let r = resourceUID[a.resourceID], let s = schedule[a.taskID], !s.isSummary else { continue }
            assignmentUID += 1
            x.open("Assignment")
            x.element("UID", assignmentUID)
            x.element("TaskUID", t)
            x.element("ResourceUID", r)
            x.element("Finish", stamp(day.finish(s.earlyFinish, on: cal)))
            x.element("Start", stamp(day.start(s.earlyStart, on: cal)))
            x.element("Units", plainNumber(a.units))
            x.element("Work", isoDuration(hours: s.duration * project.calendar.hoursPerDay * a.units))
            x.close("Assignment")
        }
        x.close("Assignments")
        x.close("Project")
        return Data(x.text.utf8)
    }

    // MARK: Import

    public static func `import`(_ data: Data) throws -> ImportResult {
        let root = try MarkupNode.parse(data)
        guard root.name == "Project" else { throw InterchangeError.unrecognized }
        let calendar = Calendar.current
        var warnings: [String] = []

        let minutesPerDay = root.number("MinutesPerDay") ?? 480
        let hoursPerDay = minutesPerDay > 0 ? minutesPerDay / 60 : 8
        let day = WorkingDay(hours: hoursPerDay)
        var project = Project(name: root.value("Title") ?? root.value("Name").map { ($0 as NSString).deletingPathExtension } ?? "Imported Project",
                              manager: root.value("Manager") ?? "")
        project.currencyCode = root.value("CurrencyCode") ?? project.currencyCode
        if let start = DateText.parse(root.value("StartDate")) { project.startDate = calendar.startOfDay(for: start) }
        project.calendar = readCalendar(root, uid: root.value("CalendarUID"), hoursPerDay: hoursPerDay, warnings: &warnings)

        // Tasks in ID order; UID 0 is the project summary row and blank rows are null tasks.
        let taskNodes = (root.first("Tasks")?.all("Task") ?? [])
            .filter { ($0.int("OutlineLevel") ?? 1) > 0 && $0.int("UID") != 0 && !$0.flag("IsNull") }
            .sorted { ($0.int("ID") ?? 0) < ($1.int("ID") ?? 0) }
        var taskID: [String: UUID] = [:]
        var skippedConstraints = 0
        for node in taskNodes {
            var task = ProjectTask(name: node.value("Name") ?? "Task", outlineLevel: max(node.int("OutlineLevel") ?? 1, 1))
            let hours = parseDuration(node.value("Duration")) ?? 0
            task.duration = node.flag("Milestone") && hours == 0 ? 0 : max((hours / hoursPerDay * 1000).rounded() / 1000, 0)
            task.percentComplete = node.number("PercentComplete") ?? 0
            task.notes = node.value("Notes") ?? ""
            let constraintDate = DateText.parse(node.value("ConstraintDate"))
            switch (node.int("ConstraintType") ?? 0, constraintDate) {
            case (0, _), (_, nil): break
            case (2, let date?):
                task.constraint = .mustStartOn
                task.constraintDate = day.startDay(date, calendar)
            case (4, let date?): task.startAfter = day.startDay(date, calendar)
            case (3, let date?), (7, let date?): task.finishBy = day.finishDay(date, calendar)
            default: skippedConstraints += 1
            }
            if let deadline = DateText.parse(node.value("Deadline")) {
                let d = day.finishDay(deadline, calendar)
                task.finishBy = task.finishBy.map { min($0, d) } ?? d
            }
            // A started task keeps its actual start.
            if let actual = DateText.parse(node.value("ActualStart")), task.constraint != .mustStartOn {
                task.startAfter = max(task.startAfter ?? .distantPast, day.startDay(actual, calendar))
            }
            if let delay = node.number("LevelingDelay"), delay > 0 {
                task.levelingDelay = delay / 10 / minutesPerDay
            }
            if let baseline = node.all("Baseline").first(where: { $0.int("Number") == 0 }),
               let bs = DateText.parse(baseline.value("Start")), let bf = DateText.parse(baseline.value("Finish")) {
                task.baselineStart = calendar.startOfDay(for: bs)
                task.baselineFinish = calendar.startOfDay(for: bf)
            }
            if let uid = node.value("UID") { taskID[uid] = task.id }
            project.tasks.append(task)
        }
        if skippedConstraints > 0 {
            warnings.append("\(skippedConstraints) constraint(s) other than Must Start On, Start No Earlier Than and Finish No Later Than were dropped.")
        }

        var percentLags = 0
        for node in taskNodes {
            guard let successor = node.value("UID").flatMap({ taskID[$0] }) else { continue }
            for link in node.all("PredecessorLink") {
                guard let predecessor = link.value("PredecessorUID").flatMap({ taskID[$0] }) else { continue }
                let format = link.int("LagFormat") ?? 7
                var lag = 0.0
                if format == 19 || format == 20 {
                    percentLags += 1
                } else {
                    let tenths = link.number("LinkLag") ?? 0
                    let elapsed = [4, 6, 8, 10, 12].contains(format)
                    lag = elapsed ? tenths / 10 / 1440 * Double(project.calendar.workingWeekdays.count) / 7 : tenths / 10 / minutesPerDay
                }
                project.dependencies.append(Dependency(predecessorID: predecessor, successorID: successor,
                                                       type: linkType(link.int("Type") ?? 1), lag: (lag * 1000).rounded() / 1000))
            }
        }
        if percentLags > 0 { warnings.append("\(percentLags) percentage lag(s) were set to zero.") }

        var resourceID: [String: UUID] = [:]
        var otherResources = 0
        for node in root.first("Resources")?.all("Resource") ?? [] {
            guard node.int("UID") != 0, !node.flag("IsNull"), let name = node.value("Name") else { continue }
            guard (node.int("Type") ?? 1) == 1 else { otherResources += 1; continue }
            let resource = Resource(name: name, initials: node.value("Initials"), group: node.value("Group") ?? "",
                                    maxUnits: node.number("MaxUnits") ?? 1, standardRate: node.number("StandardRate") ?? 0,
                                    email: node.value("EmailAddress") ?? "")
            if let uid = node.value("UID") { resourceID[uid] = resource.id }
            project.resources.append(resource)
        }
        if otherResources > 0 { warnings.append("\(otherResources) material or cost resource(s) were skipped.") }

        for node in root.first("Assignments")?.all("Assignment") ?? [] {
            guard let t = node.value("TaskUID").flatMap({ taskID[$0] }),
                  let r = node.value("ResourceUID").flatMap({ resourceID[$0] }) else { continue }
            project.assignments.append(Assignment(taskID: t, resourceID: r, units: node.number("Units") ?? 1))
        }
        return ImportResult(project: project, warnings: warnings)
    }

    // MARK: Helpers

    private static func readCalendar(_ root: MarkupNode, uid: String?, hoursPerDay: Double, warnings: inout [String]) -> CalendarSettings {
        let calendars = root.first("Calendars")?.all("Calendar") ?? []
        var settings = CalendarSettings(hoursPerDay: hoursPerDay)
        guard var node = calendars.first(where: { $0.value("UID") == uid }) ?? calendars.first else { return settings }
        // A derived calendar without its own week takes its base calendar's.
        if node.first("WeekDays")?.all("WeekDay").contains(where: { ($0.int("DayType") ?? 0) > 0 }) != true,
           let base = calendars.first(where: { $0.value("UID") == node.value("BaseCalendarUID") }) {
            node = base
        }
        let calendar = Calendar.current
        var weekdays: Set<Int> = settings.workingWeekdays
        var holidays: [Date] = []
        var recurring = 0
        func addDays(_ period: MarkupNode?) {
            guard let from = DateText.parse(period?.value("FromDate")), let to = DateText.parse(period?.value("ToDate")) else { return }
            var d = calendar.startOfDay(for: from)
            var count = 0
            while d <= to, count < 366 {
                holidays.append(d)
                d = calendar.date(byAdding: .day, value: 1, to: d)!
                count += 1
            }
        }
        for weekDay in node.first("WeekDays")?.all("WeekDay") ?? [] {
            let type = weekDay.int("DayType") ?? 0
            if (1...7).contains(type) {
                if weekDay.flag("DayWorking") { weekdays.insert(type) } else { weekdays.remove(type) }
            } else if type == 0, !weekDay.flag("DayWorking") {
                addDays(weekDay.first("TimePeriod")) // MS Project 2003 exceptions
            }
        }
        for exception in node.first("Exceptions")?.all("Exception") ?? [] where !exception.flag("DayWorking") {
            let type = exception.int("Type") ?? 1
            if type == 1, (exception.int("Period") ?? 1) == 1 {
                addDays(exception.first("TimePeriod"))
            } else {
                recurring += 1
            }
        }
        if recurring > 0 { warnings.append("\(recurring) recurring calendar exception(s) were skipped.") }
        settings.workingWeekdays = weekdays
        settings.holidays = Array(Set(holidays)).sorted()
        return settings
    }

    static func linkCode(_ type: DependencyType) -> Int {
        switch type {
        case .finishToFinish: 0
        case .finishToStart: 1
        case .startToFinish: 2
        case .startToStart: 3
        }
    }

    static func linkType(_ code: Int) -> DependencyType {
        switch code {
        case 0: .finishToFinish
        case 2: .startToFinish
        case 3: .startToStart
        default: .finishToStart
        }
    }

    /// `PT16H30M0S`
    static func isoDuration(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return "PT\(minutes / 60)H\(minutes % 60)M0S"
    }

    /// Hours in an ISO 8601 duration such as `PT16H30M0S` or `P2DT4H` (a day counted as 24 hours).
    static func parseDuration(_ text: String?) -> Double? {
        guard let text, text.hasPrefix("P") || text.hasPrefix("-P") else { return nil }
        var hours = 0.0, number = "", inTime = false
        for ch in text.dropFirst(text.hasPrefix("-") ? 2 : 1) {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            let value = Double(number) ?? 0
            number = ""
            switch ch {
            case "T": inTime = true
            case "D": hours += value * 24
            case "H": hours += value
            case "M": hours += inTime ? value / 60 : value * 24 * 30
            case "S": hours += value / 3600
            default: break
            }
        }
        return text.hasPrefix("-") ? -hours : hours
    }

    private static func clockText(_ hour: Double) -> String {
        let minutes = Int((hour * 60).rounded())
        return String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
    }
}
