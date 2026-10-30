import Foundation
import Testing
@testable import ProjectorKit

/// Same schedule shape: names, durations and dates of every leaf.
private func leafDates(_ p: Project) -> [String: [Double]] {
    let s = Scheduler.schedule(p)
    return Dictionary(uniqueKeysWithValues: p.tasks.filter { !s.outline.isSummary($0.id) }.map {
        ($0.name, [s[$0.id]!.earlyStart, s[$0.id]!.earlyFinish])
    })
}

private func sampleWithHoliday() -> Project {
    var p = Project.sample(startingOn: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2))!)
    p.calendar.holidays = [Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 26))!]
    p.tasks[1].notes = "Kick-off <with> \"quotes\" & ampersands"
    return p
}

@Test func msProjectRoundTrip() throws {
    let p = sampleWithHoliday()
    let data = Interchange.export(p, as: .msProject)
    let result = try Interchange.importFile(data)
    let q = result.project
    #expect(result.warnings.isEmpty)
    #expect(q.name == p.name)
    #expect(q.startDate == p.startDate)
    #expect(q.calendar.workingWeekdays == p.calendar.workingWeekdays)
    #expect(q.calendar.holidays == p.calendar.holidays)
    #expect(q.tasks.map(\.name) == p.tasks.map(\.name))
    #expect(q.tasks.map(\.outlineLevel) == p.tasks.map(\.outlineLevel))
    #expect(q.tasks.map(\.startAfter) == p.tasks.map(\.startAfter))
    #expect(q.tasks.map(\.finishBy) == p.tasks.map(\.finishBy))
    #expect(q.tasks[1].notes == p.tasks[1].notes)
    #expect(q.dependencies.count == p.dependencies.count)
    #expect(Set(q.dependencies.map { "\($0.type.rawValue)\($0.lag)" }) == Set(p.dependencies.map { "\($0.type.rawValue)\($0.lag)" }))
    #expect(q.resources.map(\.name) == p.resources.map(\.name))
    #expect(q.resources.map(\.standardRate) == p.resources.map(\.standardRate))
    #expect(q.assignments.count == p.assignments.count)
    #expect(leafDates(q) == leafDates(p))
}

@Test func primaveraRoundTrip() throws {
    let p = sampleWithHoliday()
    let data = Interchange.export(p, as: .primavera)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.hasPrefix("ERMHDR"))
    #expect(text.contains("%T\tTASKPRED"))
    let result = try Interchange.importFile(data)
    let q = result.project
    #expect(q.name == p.name)
    #expect(q.startDate == p.startDate)
    #expect(q.calendar.workingWeekdays == p.calendar.workingWeekdays)
    #expect(q.calendar.holidays == p.calendar.holidays)
    // Summaries come back as WBS elements, leaves as activities.
    let ps = Scheduler.schedule(p), qs = Scheduler.schedule(q)
    #expect(q.tasks.filter { qs.outline.isSummary($0.id) }.count == p.tasks.filter { ps.outline.isSummary($0.id) }.count)
    #expect(Set(q.tasks.map(\.name)) == Set(p.tasks.map(\.name)))
    #expect(q.resources.count == Set(p.assignments.map(\.resourceID)).count)
    #expect(q.assignments.count == p.assignments.count)
    #expect(qs.finishOffset == ps.finishOffset)
    #expect(leafDates(q) == leafDates(p))
}

@Test func importsHandWrittenMSProjectFile() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Project xmlns="http://schemas.microsoft.com/project">
      <Title>Bridge</Title>
      <StartDate>2026-11-02T08:00:00</StartDate>
      <MinutesPerDay>480</MinutesPerDay>
      <CalendarUID>1</CalendarUID>
      <Calendars><Calendar><UID>1</UID><Name>Standard</Name><IsBaseCalendar>1</IsBaseCalendar>
        <WeekDays>
          <WeekDay><DayType>1</DayType><DayWorking>0</DayWorking></WeekDay>
          <WeekDay><DayType>7</DayType><DayWorking>0</DayWorking></WeekDay>
          <WeekDay><DayType>0</DayType><DayWorking>0</DayWorking>
            <TimePeriod><FromDate>2026-11-11T00:00:00</FromDate><ToDate>2026-11-11T23:59:00</ToDate></TimePeriod></WeekDay>
        </WeekDays></Calendar></Calendars>
      <Tasks>
        <Task><UID>0</UID><ID>0</ID><Name>Bridge</Name><OutlineLevel>0</OutlineLevel><Summary>1</Summary></Task>
        <Task><UID>10</UID><ID>1</ID><Name>Phase</Name><OutlineLevel>1</OutlineLevel><Summary>1</Summary>
          <Deadline>2026-11-20T17:00:00</Deadline></Task>
        <Task><UID>11</UID><ID>2</ID><Name>Design</Name><OutlineLevel>2</OutlineLevel><Duration>PT24H0M0S</Duration></Task>
        <Task><UID>12</UID><ID>3</ID><Name>Build</Name><OutlineLevel>2</OutlineLevel><Duration>PT24H0M0S</Duration>
          <ConstraintType>4</ConstraintType><ConstraintDate>2026-11-04T08:00:00</ConstraintDate>
          <PredecessorLink><PredecessorUID>11</PredecessorUID><Type>3</Type><LinkLag>4800</LinkLag><LagFormat>7</LagFormat></PredecessorLink>
        </Task>
        <Task><UID>13</UID><ID>4</ID><Name>Done</Name><OutlineLevel>1</OutlineLevel><Duration>PT0H0M0S</Duration><Milestone>1</Milestone>
          <PredecessorLink><PredecessorUID>10</PredecessorUID><Type>1</Type></PredecessorLink></Task>
      </Tasks>
      <Resources>
        <Resource><UID>0</UID><ID>0</ID><IsNull>0</IsNull></Resource>
        <Resource><UID>1</UID><ID>1</ID><Name>Ann Lee</Name><Type>1</Type><MaxUnits>0.5</MaxUnits><StandardRate>90</StandardRate></Resource>
        <Resource><UID>2</UID><ID>2</ID><Name>Steel</Name><Type>0</Type></Resource>
      </Resources>
      <Assignments><Assignment><UID>1</UID><TaskUID>12</TaskUID><ResourceUID>1</ResourceUID><Units>0.5</Units></Assignment></Assignments>
    </Project>
    """
    let result = try Interchange.importFile(Data(xml.utf8))
    let p = result.project
    #expect(p.name == "Bridge")
    #expect(p.tasks.map(\.name) == ["Phase", "Design", "Build", "Done"])
    #expect(p.tasks[1...].map(\.duration) == [3, 3, 0])
    #expect(p.calendar.workingWeekdays == [2, 3, 4, 5, 6])
    #expect(p.calendar.holidays.count == 1)
    #expect(p.tasks[0].finishBy == Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20)))
    #expect(p.tasks[2].startAfter == Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4)))
    #expect(p.dependencies.count == 2)
    #expect(p.dependencies[0].type == .startToStart && p.dependencies[0].lag == 1)
    #expect(p.resources.map(\.name) == ["Ann Lee"])
    #expect(p.resources[0].maxUnits == 0.5)
    #expect(p.assignments.first?.units == 0.5)
    #expect(result.warnings.count == 1) // the material resource
    let s = Scheduler.schedule(p)
    #expect(s[p.tasks[2].id]!.earlyStart == 2) // SNET Wed 4th beats SS+1d
    #expect(s[p.tasks[3].id]!.earlyStart == 5) // after the Phase; the 11th is a holiday
}

@Test func importsHandWrittenXER() throws {
    let rows: [String] = [
        "ERMHDR\t20.12\t2026-10-30\tProject\tadmin\tadmin\tdbxDatabaseNoName\tProject Management\tEUR",
        "%T\tPROJECT", "%F\tproj_id\tproj_short_name\tclndr_id\tplan_start_date",
        "%R\t7\tBRIDGE\t3\t2026-11-02 08:00",
        "%T\tCALENDAR", "%F\tclndr_id\tdefault_flag\tclndr_name\tday_hr_cnt\tclndr_data",
        "%R\t3\tY\tSix day\t10\t(0||CalendarData()(\u{7F}\u{7F}(0||DaysOfWeek()(\u{7F}\u{7F}(0||1()())(0||2()((0||0(s|07:00|f|17:00)())))"
            + "(0||3()((0||0(s|07:00|f|17:00)())))(0||4()((0||0(s|07:00|f|17:00)())))(0||5()((0||0(s|07:00|f|17:00)())))"
            + "(0||6()((0||0(s|07:00|f|17:00)())))(0||7()((0||0(s|07:00|f|12:00)())))))"
            + "(0||VIEW(ShowTotal|Y)())(0||Exceptions()((0||0(d|46339)())(0||1(d|46340)((0||0(s|08:00|f|12:00)()))))))",
        "%T\tPROJWBS", "%F\twbs_id\tproj_id\tseq_num\tproj_node_flag\twbs_short_name\twbs_name\tparent_wbs_id",
        "%R\t70\t7\t0\tY\tBRIDGE\tRiver Bridge\t",
        "%R\t71\t7\t2\tN\tB\tBuild\t70",
        "%R\t72\t7\t1\tN\tD\tDesign\t70",
        "%R\t73\t7\t3\tN\tE\tEmpty\t70",
        "%T\tTASK", "%F\ttask_id\tproj_id\twbs_id\ttask_code\ttask_name\ttask_type\ttarget_drtn_hr_cnt\tcstr_type\tcstr_date\tearly_start_date",
        "%R\t1\t7\t72\tA10\tSurvey\tTT_Task\t20\t\t\t2026-11-02 07:00",
        "%R\t2\t7\t71\tA20\tPiers\tTT_Task\t50\tCS_MEOB\t2026-11-20 17:00\t2026-11-04 07:00",
        "%R\t3\t7\t70\tA30\tOpen\tTT_FinMile\t0\t\t\t2026-11-11 17:00",
        "%T\tTASKPRED", "%F\ttask_pred_id\ttask_id\tpred_task_id\tproj_id\tpred_proj_id\tpred_type\tlag_hr_cnt",
        "%R\t1\t2\t1\t7\t7\tPR_FS\t10",
        "%R\t2\t3\t2\t7\t7\tPR_FF\t0",
        "%R\t3\t3\t99\t7\t8\tPR_FS\t0",
        "%T\tRSRC", "%F\trsrc_id\tparent_rsrc_id\trsrc_name\trsrc_short_name\trsrc_type",
        "%R\t5\t\tCrews\tCREWS\tRT_Labor",
        "%R\t6\t5\tCrew A\tCA\tRT_Labor",
        "%T\tRSRCRATE", "%F\trsrc_rate_id\trsrc_id\tmax_qty_per_hr\tcost_per_qty\tstart_date",
        "%R\t1\t6\t2\t120\t2020-01-01 00:00",
        "%T\tTASKRSRC", "%F\ttaskrsrc_id\ttask_id\tproj_id\trsrc_id\ttarget_qty_per_hr",
        "%R\t1\t2\t7\t6\t2",
        "%E",
    ]
    let result = try Interchange.importFile(Data(rows.joined(separator: "\r\n").utf8))
    let p = result.project
    #expect(p.name == "River Bridge")
    #expect(p.currencyCode == "EUR")
    #expect(p.calendar.hoursPerDay == 10)
    #expect(p.calendar.workingWeekdays == [2, 3, 4, 5, 6, 7])
    #expect(p.calendar.holidays.count == 1) // 46340 has hours, so it's a working exception
    #expect(p.tasks.map(\.name) == ["Open", "Design", "Survey", "Build", "Piers"])
    #expect(p.tasks.map(\.outlineLevel) == [1, 1, 2, 1, 2])
    #expect(p.tasks[2].duration == 2)
    #expect(p.tasks[4].duration == 5)
    #expect(p.tasks[4].finishBy == Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20)))
    #expect(p.tasks[0].duration == 0)
    #expect(p.dependencies.count == 2)
    #expect(p.dependencies[0].lag == 1)
    #expect(p.dependencies[1].type == .finishToFinish)
    #expect(p.resources.map(\.name) == ["Crew A"])
    #expect(p.resources[0].group == "Crews")
    #expect(p.resources[0].maxUnits == 2 && p.resources[0].standardRate == 120)
    #expect(p.assignments.first?.units == 2)
    #expect(result.warnings.contains { $0.contains("other projects") })
}

@Test func rejectsOtherFiles() {
    #expect(throws: InterchangeError.self) { try Interchange.importFile(Data("hello".utf8)) }
    #expect(throws: InterchangeError.self) { try Interchange.importFile(Data("<html></html>".utf8)) }
}
