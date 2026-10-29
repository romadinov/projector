import Foundation
import Testing
@testable import ProjectorKit

/// Monday 2 Nov 2026 in a fixed calendar.
private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()
private let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!

private func date(_ day: Int, month: Int = 11) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
}

private func schedule(_ p: Project) -> Schedule {
    // Scheduler uses Calendar.current; tests compare day indices, which are calendar-independent.
    Scheduler.schedule(p)
}

@Test func calendarSkipsWeekendsAndHolidays() {
    let settings = CalendarSettings(holidays: [date(4)])
    let cal = WorkCalendar(settings: settings, projectStart: monday, calendar: calendar)
    #expect(cal.date(forDay: 0) == date(2))
    #expect(cal.date(forDay: 1) == date(3))
    #expect(cal.date(forDay: 2) == date(5)) // 4th is a holiday
    #expect(cal.date(forDay: 4) == date(9)) // skips the weekend
    #expect(cal.dayIndex(onOrAfter: date(7)) == 4)
    #expect(cal.dayIndex(onOrBefore: date(7)) == 3)
    #expect(cal.calendarOffset(forDay: 4) == 7)
}

@Test func finishToStartChainAndCriticalPath() {
    var p = Project(startDate: monday)
    let a = ProjectTask(name: "A", duration: 5)
    let b = ProjectTask(name: "B", duration: 3)
    let c = ProjectTask(name: "C", duration: 2)
    p.tasks = [a, b, c]
    p.dependencies = [Dependency(predecessorID: a.id, successorID: b.id)]
    let s = schedule(p)
    #expect(s[b.id]!.earlyStart == 5)
    #expect(s[b.id]!.earlyFinish == 8)
    #expect(s.finishOffset == 8)
    #expect(s[a.id]!.isCritical)
    #expect(s[b.id]!.isCritical)
    #expect(s[c.id]!.totalSlack == 6)
    #expect(!s[c.id]!.isCritical)
}

@Test func allLinkTypesAndLag() {
    var p = Project(startDate: monday)
    let a = ProjectTask(name: "A", duration: 4)
    let ss = ProjectTask(name: "SS", duration: 2)
    let ff = ProjectTask(name: "FF", duration: 2)
    let sf = ProjectTask(name: "SF", duration: 3)
    let lag = ProjectTask(name: "Lag", duration: 1)
    p.tasks = [a, ss, ff, sf, lag]
    p.dependencies = [
        Dependency(predecessorID: a.id, successorID: ss.id, type: .startToStart, lag: 1),
        Dependency(predecessorID: a.id, successorID: ff.id, type: .finishToFinish),
        Dependency(predecessorID: a.id, successorID: sf.id, type: .startToFinish, lag: 5),
        Dependency(predecessorID: a.id, successorID: lag.id, lag: -1),
    ]
    let s = schedule(p)
    #expect(s[ss.id]!.earlyStart == 1)
    #expect(s[ff.id]!.earlyFinish == 4)
    #expect(s[sf.id]!.earlyFinish == 5)
    #expect(s[lag.id]!.earlyStart == 3)
}

@Test func summaryRollsUpAndPassesLinksToChildren() {
    var p = Project(startDate: monday)
    let before = ProjectTask(name: "Before", duration: 2)
    let phase = ProjectTask(name: "Phase", outlineLevel: 1)
    let x = ProjectTask(name: "X", outlineLevel: 2, duration: 3)
    let y = ProjectTask(name: "Y", outlineLevel: 2, duration: 1)
    let after = ProjectTask(name: "After", duration: 1)
    p.tasks = [before, phase, x, y, after]
    p.dependencies = [
        Dependency(predecessorID: before.id, successorID: phase.id),
        Dependency(predecessorID: phase.id, successorID: after.id),
    ]
    let s = schedule(p)
    #expect(s[x.id]!.earlyStart == 2)
    #expect(s[y.id]!.earlyStart == 2)
    #expect(s[phase.id]!.isSummary)
    #expect(s[phase.id]!.earlyStart == 2)
    #expect(s[phase.id]!.earlyFinish == 5)
    #expect(s[after.id]!.earlyStart == 5)
    #expect(s.outline.wbs[x.id] == "2.1")
    #expect(s.outline.wbs[after.id] == "3")
    #expect(s[y.id]!.totalSlack == 2)
}

@Test func circularLinksAreRejected() throws {
    var p = Project(startDate: monday)
    let a = ProjectTask(name: "A"), b = ProjectTask(name: "B")
    p.tasks = [a, b]
    try p.addDependency(Dependency(predecessorID: a.id, successorID: b.id))
    #expect(throws: EditError.circularDependency) {
        try p.addDependency(Dependency(predecessorID: b.id, successorID: a.id))
    }
}

@Test func constraintsMoveTasks() {
    var p = Project(startDate: monday)
    var a = ProjectTask(name: "A", duration: 2)
    a.constraint = .startNoEarlierThan
    a.constraintDate = calendar.date(byAdding: .day, value: 7, to: monday)
    p.tasks = [a]
    let s = Scheduler.schedule(p)
    #expect(s[a.id]!.earlyStart == 5)
}

@Test func notationParsing() {
    let settings = CalendarSettings()
    #expect(Notation.parseDuration("5d", settings: settings) == 5)
    #expect(Notation.parseDuration("2 weeks", settings: settings) == 10)
    #expect(Notation.parseDuration("4h", settings: settings) == 0.5)
    #expect(Notation.parseDuration("abc", settings: settings) == nil)
    #expect(Notation.parsePredecessors("3, 4SS+2d,5FF-1", settings: settings) == [
        .init(row: 3), .init(row: 4, type: .startToStart, lag: 2), .init(row: 5, type: .finishToFinish, lag: -1),
    ])
    #expect(Notation.parsePredecessors("3XX", settings: settings) == nil)
    #expect(Notation.formatPredecessor(row: 4, type: .startToStart, lag: 2) == "4SS+2d")
    #expect(Notation.parseResources("Ann, Bob[50%]") == [.init(name: "Ann", units: 1), .init(name: "Bob", units: 0.5)])
}

@Test func outlineEditing() throws {
    var p = Project(startDate: monday)
    let a = p.insertTask(named: "A", after: nil)
    let b = p.insertTask(named: "B", after: a)
    let c = p.insertTask(named: "C", after: b)
    p.indent([b, c])
    #expect(p.tasks.map(\.outlineLevel) == [1, 2, 2])
    p.indent([c]) // C under B
    #expect(p.tasks.map(\.outlineLevel) == [1, 2, 3])
    p.outdent([b]) // B and its child move out together
    #expect(p.tasks.map(\.outlineLevel) == [1, 1, 2])
    p.moveUp(b)
    #expect(p.tasks.map(\.name) == ["B", "C", "A"])
    p.moveDown(b)
    #expect(p.tasks.map(\.name) == ["A", "B", "C"])
    try p.setPredecessors(of: b, text: "1")
    try p.setResources(of: b, text: "Ann[50%]")
    #expect(p.resources.map(\.name) == ["Ann"])
    p.deleteTasks([b])
    #expect(p.tasks.map(\.name) == ["A"])
    #expect(p.dependencies.isEmpty)
    #expect(p.assignments.isEmpty)
}

@Test func levelingRemovesOverallocation() {
    var p = Project(startDate: monday)
    let ann = Resource(name: "Ann")
    let a = ProjectTask(name: "A", duration: 3)
    let b = ProjectTask(name: "B", duration: 2)
    p.tasks = [a, b]
    p.resources = [ann]
    p.assignments = [Assignment(taskID: a.id, resourceID: ann.id), Assignment(taskID: b.id, resourceID: ann.id)]
    #expect(Scheduler.schedule(p).resourceLoads[ann.id]!.isOverallocated)
    let result = Leveler.level(p)
    let s = Scheduler.schedule(result.project)
    #expect(!s.resourceLoads[ann.id]!.isOverallocated)
    #expect(s.finishOffset == 5)
    #expect(result.delayedTaskCount == 1)
}

@Test func sampleProjectSchedulesAndLevels() throws {
    let p = Project.sample()
    let s = Scheduler.schedule(p)
    #expect(s.cycleTaskIDs.isEmpty)
    #expect(s.finishOffset > 20)
    let leveled = Leveler.level(p)
    let ls = Scheduler.schedule(leveled.project)
    #expect(ls.resourceLoads.values.allSatisfy { !$0.isOverallocated })
    let data = try p.encoded()
    #expect(try Project.decode(from: data) == p)
}

@Test func quickPlanParsesOutlineLinksAndResources() {
    let text = """
    # Website
    Discovery
      Kickoff milestone @Priya
      Interviews 4d after Kickoff @Priya, @Diego[50%]
      Audit 3d after Kickoff SS+1d
    Phase 2
      - Build (2w) after Discovery
      Test 3 days after build, Audit FF
    Launch 0d after 7
    """
    let result = QuickPlan.parse(text, into: Project(startDate: monday))
    let p = result.project
    #expect(result.warnings.isEmpty, "\(result.warnings)")
    #expect(p.tasks.map(\.name) == ["Discovery", "Kickoff", "Interviews", "Audit", "Phase 2", "Build", "Test", "Launch"])
    #expect(p.tasks.map(\.outlineLevel) == [1, 2, 2, 2, 1, 2, 2, 1])
    #expect(p.tasks[1].duration == 0)
    #expect(p.tasks[5].duration == 10)
    #expect(p.tasks[6].duration == 3)
    #expect(p.resources.map(\.name) == ["Priya", "Diego"])
    let s = Scheduler.schedule(p)
    #expect(s[p.tasks[3].id]!.earlyStart == 1) // SS+1d
    #expect(s[p.tasks[5].id]!.earlyStart == 4) // after Discovery (Interviews 0..4)
    #expect(s[p.tasks[6].id]!.earlyStart == 14)
    #expect(s[p.tasks[7].id]!.earlyStart == 17)
    // Round trip.
    let again = QuickPlan.parse(QuickPlan.render(p), into: Project(startDate: monday)).project
    #expect(Scheduler.schedule(again).finishOffset == s.finishOffset)
    #expect(again.dependencies.count == p.dependencies.count)
}

@Test func quickPlanWarnsOnUnknownReference() {
    let result = QuickPlan.parse("A 2d\nB 1d after Nope", into: Project(startDate: monday))
    #expect(result.warnings.count == 1)
    #expect(result.project.tasks.count == 2)
}

@Test func timephasedWorkAddsUpAcrossPeriods() {
    var p = Project(startDate: monday)
    let ann = Resource(name: "Ann", maxUnits: 1)
    let a = ProjectTask(name: "A", duration: 7)
    let b = ProjectTask(name: "B", duration: 2.5)
    p.tasks = [a, b]
    p.resources = [ann]
    let aa = Assignment(taskID: a.id, resourceID: ann.id)
    let ba = Assignment(taskID: b.id, resourceID: ann.id, units: 0.5)
    p.assignments = [aa, ba]
    let s = Scheduler.schedule(p)
    for timescale in Timescale.allCases {
        let periods = s.periods(timescale)
        #expect(abs(periods.reduce(0) { $0 + s.work(of: aa, in: $1) } - 56) < 1e-9, "\(timescale)")
        #expect(abs(periods.reduce(0) { $0 + s.work(of: ba, in: $1) } - 10) < 1e-9, "\(timescale)")
        #expect(abs(periods.reduce(0) { $0 + s.work(ofResource: ann.id, in: $1) } - 66) < 1e-9, "\(timescale)")
    }
    // Daily: 8h + 4h on the first day (A full-time, B half-time) is overallocated.
    let days = s.periods(.day)
    #expect(s.work(ofResource: ann.id, in: days[0]) == 12)
    #expect(s.isOverallocated(ann, in: days[0]))
    #expect(s.capacity(of: ann, in: days[0]) == 8)
    // Weekends have no working days.
    #expect(days[5].workingDayCount == 0)
    #expect(s.work(ofResource: ann.id, in: days[5]) == 0)
}

@Test func startAfterAndDeadlines() throws {
    var p = Project(startDate: monday)
    let a = ProjectTask(name: "A", duration: 3)
    var phase = ProjectTask(name: "Phase", duration: 0)
    var b = ProjectTask(name: "B", outlineLevel: 2, duration: 2)
    let c = ProjectTask(name: "C", outlineLevel: 2, duration: 4)
    // The phase can't start before next Monday; B must be done by Wednesday of that week.
    phase.startAfter = calendar.date(byAdding: .day, value: 7, to: monday)
    b.finishBy = calendar.date(byAdding: .day, value: 9, to: monday)
    p.tasks = [a, phase, b, c]
    try p.addDependency(Dependency(predecessorID: a.id, successorID: b.id))
    var s = Scheduler.schedule(p)
    #expect(s[b.id]!.earlyStart == 5)        // held back by the phase, not by A
    #expect(s[c.id]!.earlyStart == 5)
    #expect(s[b.id]!.lateFinish == 8)        // end of Wednesday
    #expect(s[b.id]!.totalSlack == 1)
    #expect(!s[b.id]!.missesDeadline)

    // Deadline on Tuesday: B finishes exactly on time and becomes critical.
    p.tasks[2].finishBy = calendar.date(byAdding: .day, value: 8, to: monday)
    s = Scheduler.schedule(p)
    #expect(!s[b.id]!.missesDeadline && s[b.id]!.totalSlack == 0 && s[b.id]!.isCritical)

    // Deadline on Monday: B is a day late, its slack goes negative and the phase is flagged.
    p.tasks[2].finishBy = calendar.date(byAdding: .day, value: 7, to: monday)
    s = Scheduler.schedule(p)
    #expect(s[b.id]!.missesDeadline && s[b.id]!.totalSlack == -1)
    #expect(s[phase.id]!.missesDeadline)
    #expect(s[a.id]!.totalSlack == 1)        // A still has a day before B must start

    // A deadline on the phase applies to its subtasks.
    p.tasks[2].finishBy = nil
    p.tasks[1].finishBy = calendar.date(byAdding: .day, value: 7, to: monday)
    s = Scheduler.schedule(p)
    #expect(s[b.id]!.missesDeadline && s[c.id]!.missesDeadline)
    #expect(s[b.id]!.totalSlack == -1 && s[b.id]!.isCritical)
    #expect(s.missedDeadlineCount == 2)
}

@Test func quickPlanDates() {
    let text = """
    Build after 2026-11-16 by 2026-12-18
      Code 2w
      Test 1w after Code by 2026-12-04
    """
    let result = QuickPlan.parse(text, into: Project(startDate: monday))
    let build = result.project.tasks[0], test = result.project.tasks[2]
    #expect(result.warnings.isEmpty)
    #expect(build.startAfter == Notation.parseDate("2026-11-16"))
    #expect(build.finishBy == Notation.parseDate("2026-12-18"))
    #expect(test.finishBy == Notation.parseDate("2026-12-04"))
    #expect(result.project.dependencies.count == 1)
    let rendered = QuickPlan.render(result.project)
    #expect(rendered.contains("Build after 2026-11-16 by 2026-12-18"))
    #expect(rendered.contains("Test 5d after Code by 2026-12-04"))
}
