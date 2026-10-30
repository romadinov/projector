import Foundation

/// Primavera P6 XER: tab-separated tables (`%T` name, `%F` field names, `%R` rows, `%E` end).
///
/// P6 has no summary activities: a summary task becomes a WBS element and its subtasks the activities
/// under it. Durations, lags and float are in hours; dates are `yyyy-MM-dd HH:mm` in local time.
public enum PrimaveraXER {

    // MARK: Export

    public static func export(_ project: Project) -> Data {
        let schedule = Scheduler.schedule(project)
        let outline = schedule.outline
        let cal = schedule.calendar
        let hours = project.calendar.hoursPerDay
        let day = WorkingDay(hours: hours)
        let stamp = { (date: Date) in DateText.format(date, seconds: false) }
        let today = stamp(Date())
        let projID = "1", clndrID = "1", currID = "1", projectWBS = "100"
        let shortName = projectShortName(project.name)
        var tables: [(name: String, rows: [[String: String]])] = []

        let symbol = Locale(identifier: Locale.identifier(fromComponents: ["currency": project.currencyCode]))
            .currencySymbol ?? project.currencyCode
        tables.append(("CURRTYPE", [[
            "curr_id": currID, "decimal_digit_cnt": "2", "curr_symbol": symbol, "decimal_symbol": ".",
            "digit_group_symbol": ",", "pos_curr_fmt_type": "#1.1", "neg_curr_fmt_type": "(#1.1)",
            "curr_type": project.currencyCode, "curr_short_name": project.currencyCode, "group_digit_cnt": "3", "base_exch_rate": "1",
        ]]))

        tables.append(("PROJECT", [[
            "proj_id": projID, "fy_start_month_num": "1", "rsrc_self_add_flag": "Y", "allow_complete_flag": "Y",
            "rsrc_multi_assign_flag": "Y", "checkout_flag": "N", "project_flag": "Y", "step_complete_flag": "N",
            "cost_qty_recalc_flag": "Y", "batch_sum_flag": "Y", "name_sep_char": ".", "def_complete_pct_type": "CP_Phys",
            "proj_short_name": shortName, "clndr_id": clndrID, "task_code_base": "1000", "task_code_step": "10",
            "priority_num": "10", "wbs_max_sum_level": "0", "strgy_priority_num": "100", "critical_drtn_hr_cnt": "0",
            "def_cost_per_qty": "0", "last_recalc_date": stamp(day.start(0, on: cal)), "plan_start_date": stamp(day.start(0, on: cal)),
            "scd_end_date": stamp(day.finish(schedule.finishOffset, on: cal)), "add_date": today,
            "def_duration_type": "DT_FixedDUR2", "task_code_prefix": "A", "def_qty_type": "QT_Hour", "add_by_name": "admin",
            "def_rate_type": "COST_PER_QTY", "add_act_remain_flag": "N", "act_this_per_link_flag": "Y", "def_task_type": "TT_Task",
            "act_pct_link_flag": "N", "critical_path_type": "CT_TotFloat", "task_code_prefix_flag": "Y",
            "def_rollup_dates_flag": "Y", "use_project_baseline_flag": "Y", "rem_target_link_flag": "Y",
            "reset_planned_flag": "N", "allow_neg_act_flag": "N", "sum_assign_level": "SL_Taskrsrc", "export_flag": "Y",
        ]]))

        let weekHours = hours * Double(project.calendar.workingWeekdays.count)
        tables.append(("CALENDAR", [[
            "clndr_id": clndrID, "default_flag": "Y", "clndr_name": "Standard", "proj_id": projID, "last_chng_date": today,
            "clndr_type": "CA_Project", "day_hr_cnt": plainNumber(hours), "week_hr_cnt": plainNumber(weekHours),
            "month_hr_cnt": plainNumber((weekHours * 52 / 12).rounded()), "year_hr_cnt": plainNumber(weekHours * 52),
            "rsrc_private": "N", "clndr_data": calendarData(project.calendar, day: day, calendar: cal.calendar),
        ]]))

        tables.append(("SCHEDOPTIONS", [[
            "schedoptions_id": "1", "proj_id": projID, "sched_outer_depend_type": "SD_Both", "sched_open_critical_flag": "N",
            "sched_lag_early_start_flag": "Y", "sched_retained_logic": "Y", "sched_setplantoforecast": "N",
            "sched_float_type": "FT_Min", "sched_calendar_on_relationship_lag": "rcal_Predecessor",
            "sched_use_expect_end_flag": "Y", "sched_progress_override": "N", "level_float_thrs_cnt": "1",
            "level_outer_assign_flag": "N", "level_outer_assign_priority": "5", "level_over_alloc_pct": "25",
            "level_within_float_flag": "N", "level_keep_sched_date_flag": "Y", "level_all_rsrc_flag": "Y",
            "sched_use_project_end_date_for_float": "Y", "enable_multiple_longest_path_calc": "N",
            "limit_multiple_longest_path_calc": "Y", "max_multiple_longest_path": "10",
            "use_total_float_multiple_longest_paths": "Y", "LevelPriorityList": "priority_type,ASC_BY_FIELD/ASC",
        ]]))

        // WBS: the project node, then one element per summary task.
        func wbsRow(_ id: String, seq: Int, projectNode: Bool, code: String, name: String, parent: String) -> [String: String] {
            ["wbs_id": id, "proj_id": projID, "seq_num": String(seq), "est_wt": "1", "proj_node_flag": projectNode ? "Y" : "N",
             "sum_data_flag": projectNode ? "Y" : "N", "status_code": "WS_Open", "wbs_short_name": code, "wbs_name": clean(name),
             "parent_wbs_id": parent, "ev_user_pct": "6", "ev_etc_user_value": "0.88", "orig_cost": "0",
             "indep_remain_total_cost": "0", "indep_remain_work_qty": "0", "ev_compute_type": "EC_Cmp_pct",
             "ev_etc_compute_type": "EE_PF_cpi"]
        }
        var wbsID: [UUID: String] = [:]
        var wbsRows = [wbsRow(projectWBS, seq: 0, projectNode: true, code: shortName, name: project.name, parent: "")]
        for (i, task) in project.tasks.enumerated() where outline.isSummary(task.id) {
            let id = String(200 + i)
            wbsID[task.id] = id
            let parent = outline.parent[task.id].flatMap { wbsID[$0] } ?? projectWBS
            let code = outline.wbs[task.id]?.split(separator: ".").last.map(String.init) ?? String(i)
            wbsRows.append(wbsRow(id, seq: i + 1, projectNode: false, code: code, name: task.name, parent: parent))
        }
        tables.append(("PROJWBS", wbsRows))

        // Resources: short names must be unique.
        var rsrcID: [UUID: String] = [:]
        var usedShortNames: Set<String> = []
        var rsrcRows: [[String: String]] = [], rateRows: [[String: String]] = []
        for (i, r) in project.resources.enumerated() {
            let id = String(i + 1)
            rsrcID[r.id] = id
            let base = (r.initials.isEmpty ? Resource.defaultInitials(for: r.name) : r.initials).uppercased()
            var short = base.isEmpty ? "R\(i + 1)" : base
            var n = 2
            while usedShortNames.contains(short) { short = base + String(n); n += 1 }
            usedShortNames.insert(short)
            rsrcRows.append([
                "rsrc_id": id, "clndr_id": clndrID, "rsrc_seq_num": String(i + 1), "email_addr": clean(r.email),
                "rsrc_name": clean(r.name), "rsrc_short_name": short, "rsrc_title_name": clean(r.group),
                "def_qty_per_hr": plainNumber(r.maxUnits), "cost_qty_type": "QT_Hour", "ot_factor": "1", "active_flag": "Y",
                "auto_compute_act_flag": "Y", "def_cost_qty_link_flag": "Y", "ot_flag": "N", "curr_id": currID,
                "rsrc_type": "RT_Labor",
            ])
            rateRows.append(["rsrc_rate_id": id, "rsrc_id": id, "max_qty_per_hr": plainNumber(r.maxUnits),
                             "cost_per_qty": plainNumber(r.standardRate), "start_date": stamp(day.start(0, on: cal))])
        }
        tables.append(("RSRC", rsrcRows))
        tables.append(("RSRCRATE", rateRows))

        // Activities: leaves. A summary's start and deadline limits pass down to its subtasks.
        var taskID: [UUID: String] = [:]
        var taskRows: [[String: String]] = []
        let leaves = project.tasks.filter { !outline.isSummary($0.id) }
        for (i, task) in leaves.enumerated() {
            guard let s = schedule[task.id] else { continue }
            let id = String(1000 + i)
            taskID[task.id] = id
            let lineage = [task] + outline.ancestors(of: task.id).compactMap(project.task)
            let startAfter = lineage.compactMap(\.earliestStart).max()
            let finishBy = lineage.compactMap(\.finishBy).min()
            var constraint: (type: String, date: String)?, secondary: (type: String, date: String)?
            if task.constraint == .mustStartOn, let date = task.constraintDate {
                constraint = ("CS_MANDSTART", stamp(day.at(date, hour: day.periods[0].from, cal.calendar)))
            } else if let date = startAfter {
                constraint = ("CS_MSOA", stamp(day.at(date, hour: day.periods[0].from, cal.calendar)))
            }
            if let date = finishBy {
                let value = ("CS_MEOB", stamp(day.at(date, hour: day.endHour, cal.calendar)))
                if constraint == nil { constraint = value } else if constraint?.type == "CS_MSOA" { secondary = value }
            }
            let milestone = task.duration == 0
            let start = stamp(milestone ? day.finish(s.earlyStart, on: cal) : day.start(s.earlyStart, on: cal))
            let finish = stamp(milestone ? day.finish(s.earlyStart, on: cal) : day.finish(s.earlyFinish, on: cal))
            let lateStart = stamp(milestone ? day.finish(s.lateStart, on: cal) : day.start(s.lateStart, on: cal))
            let lateFinish = stamp(milestone ? day.finish(s.lateStart, on: cal) : day.finish(s.lateFinish, on: cal))
            let durationHours = plainNumber(s.duration * hours)
            let work = plainNumber(project.assignments.filter { $0.taskID == task.id }.reduce(0) { $0 + $1.units } * s.duration * hours)
            taskRows.append([
                "task_id": id, "proj_id": projID, "wbs_id": outline.parent[task.id].flatMap { wbsID[$0] } ?? projectWBS,
                "clndr_id": clndrID, "phys_complete_pct": plainNumber(s.percentComplete), "rev_fdbk_flag": "N", "est_wt": "1",
                "lock_plan_flag": "N", "auto_compute_act_flag": "N", "complete_pct_type": "CP_Phys",
                "task_type": milestone ? (s.earlyStart > 0 ? "TT_FinMile" : "TT_Mile") : "TT_Task",
                "duration_type": "DT_FixedDUR2", "status_code": "TK_NotStart", "task_code": "A\(1000 + i * 10)",
                "task_name": clean(task.name), "total_float_hr_cnt": plainNumber(s.totalSlack * hours), "free_float_hr_cnt": "0",
                "remain_drtn_hr_cnt": durationHours, "act_work_qty": "0", "remain_work_qty": work, "target_work_qty": work,
                "target_drtn_hr_cnt": durationHours, "target_equip_qty": "0", "act_equip_qty": "0", "remain_equip_qty": "0",
                "cstr_date": constraint?.date ?? "", "late_start_date": lateStart, "late_end_date": lateFinish,
                "early_start_date": start, "early_end_date": finish, "restart_date": start, "reend_date": finish,
                "target_start_date": start, "target_end_date": finish, "rem_late_start_date": lateStart,
                "rem_late_end_date": lateFinish, "cstr_type": constraint?.type ?? "", "priority_type": "PT_Normal",
                "cstr_date2": secondary?.date ?? "", "cstr_type2": secondary?.type ?? "", "driving_path_flag": "N",
                "act_this_per_work_qty": "0", "act_this_per_equip_qty": "0",
            ])
        }
        tables.append(("TASK", taskRows))

        // Links; one on a summary task links each of its subtasks.
        var seen: Set<[String]> = []
        var predRows: [[String: String]] = []
        for d in project.dependencies {
            for p in outline.leaves(of: d.predecessorID) {
                for s in outline.leaves(of: d.successorID) {
                    guard let pid = taskID[p], let sid = taskID[s], pid != sid, seen.insert([pid, sid]).inserted else { continue }
                    predRows.append(["task_pred_id": String(predRows.count + 1), "task_id": sid, "pred_task_id": pid,
                                     "proj_id": projID, "pred_proj_id": projID, "pred_type": "PR_" + d.type.rawValue,
                                     "lag_hr_cnt": plainNumber(d.lag * hours)])
                }
            }
        }
        tables.append(("TASKPRED", predRows))

        var assignmentRows: [[String: String]] = []
        for a in project.assignments {
            guard let t = taskID[a.taskID], let r = rsrcID[a.resourceID], let s = schedule[a.taskID],
                  let rate = project.resource(a.resourceID)?.standardRate else { continue }
            let qty = plainNumber(s.duration * hours * a.units), cost = plainNumber(s.duration * hours * a.units * rate)
            let start = stamp(day.start(s.earlyStart, on: cal)), finish = stamp(day.finish(s.earlyFinish, on: cal))
            assignmentRows.append([
                "taskrsrc_id": String(assignmentRows.count + 1), "task_id": t, "proj_id": projID, "cost_qty_link_flag": "Y",
                "rsrc_id": r, "remain_qty": qty, "target_qty": qty, "remain_qty_per_hr": plainNumber(a.units),
                "target_lag_drtn_hr_cnt": "0", "target_qty_per_hr": plainNumber(a.units), "act_ot_qty": "0", "act_reg_qty": "0",
                "cost_per_qty": plainNumber(rate), "target_cost": cost, "act_reg_cost": "0", "act_ot_cost": "0",
                "remain_cost": cost, "restart_date": start, "reend_date": finish, "target_start_date": start,
                "target_end_date": finish, "rollup_dates_flag": "Y", "ts_pend_act_end_flag": "N", "rate_type": "COST_PER_QTY",
                "act_this_per_cost": "0", "act_this_per_qty": "0", "rsrc_type": "RT_Labor", "cost_per_qty_source_type": "ST_Rsrc",
            ])
        }
        tables.append(("TASKRSRC", assignmentRows))

        var lines = ["ERMHDR\t19.12\t\(today.prefix(10))\tProject\tadmin\tProjector\tdbxDatabaseNoName\tProject Management\t\(project.currencyCode)"]
        for table in tables {
            let fields = Self.fields[table.name]!
            lines.append("%T\t" + table.name)
            lines.append("%F\t" + fields.joined(separator: "\t"))
            for row in table.rows { lines.append("%R\t" + fields.map { row[$0] ?? "" }.joined(separator: "\t")) }
        }
        lines.append("%E")
        let text = lines.joined(separator: "\r\n") + "\r\n"
        // P6 writes Windows-1252; fall back to UTF-8 for names it can't hold.
        return text.data(using: .windowsCP1252) ?? Data(text.utf8)
    }

    /// Every column of each table, in the order P6 exports them; columns Projector has no value for stay empty.
    static let fields: [String: [String]] = [
        "CURRTYPE": "curr_id decimal_digit_cnt curr_symbol decimal_symbol digit_group_symbol pos_curr_fmt_type neg_curr_fmt_type curr_type curr_short_name group_digit_cnt base_exch_rate",
        "PROJECT": "proj_id fy_start_month_num rsrc_self_add_flag allow_complete_flag rsrc_multi_assign_flag checkout_flag project_flag step_complete_flag cost_qty_recalc_flag batch_sum_flag name_sep_char def_complete_pct_type proj_short_name acct_id orig_proj_id source_proj_id base_type_id clndr_id sum_base_proj_id task_code_base task_code_step priority_num wbs_max_sum_level strgy_priority_num last_checksum critical_drtn_hr_cnt def_cost_per_qty last_recalc_date plan_start_date plan_end_date scd_end_date add_date last_tasksum_date fcst_start_date def_duration_type task_code_prefix guid def_qty_type add_by_name web_local_root_path proj_url def_rate_type add_act_remain_flag act_this_per_link_flag def_task_type act_pct_link_flag critical_path_type task_code_prefix_flag def_rollup_dates_flag use_project_baseline_flag rem_target_link_flag reset_planned_flag allow_neg_act_flag sum_assign_level last_fin_dates_id fintmpl_id last_baseline_update_date cr_external_key apply_actuals_date location_id loaded_scope_level export_flag new_fin_dates_id baselines_to_export baseline_names_to_export next_data_date close_period_flag sum_refresh_date trsrcsum_loaded sumtask_loaded",
        "CALENDAR": "clndr_id default_flag clndr_name proj_id base_clndr_id last_chng_date clndr_type day_hr_cnt week_hr_cnt month_hr_cnt year_hr_cnt rsrc_private clndr_data",
        "SCHEDOPTIONS": "schedoptions_id proj_id sched_outer_depend_type sched_open_critical_flag sched_lag_early_start_flag sched_retained_logic sched_setplantoforecast sched_float_type sched_calendar_on_relationship_lag sched_use_expect_end_flag sched_progress_override level_float_thrs_cnt level_outer_assign_flag level_outer_assign_priority level_over_alloc_pct level_within_float_flag level_keep_sched_date_flag level_all_rsrc_flag sched_use_project_end_date_for_float enable_multiple_longest_path_calc limit_multiple_longest_path_calc max_multiple_longest_path use_total_float_multiple_longest_paths key_activity_for_multiple_longest_paths LevelPriorityList",
        "PROJWBS": "wbs_id proj_id obs_id seq_num est_wt proj_node_flag sum_data_flag status_code wbs_short_name wbs_name phase_id parent_wbs_id ev_user_pct ev_etc_user_value orig_cost indep_remain_total_cost ann_dscnt_rate_pct dscnt_period_type indep_remain_work_qty anticip_start_date anticip_end_date ev_compute_type ev_etc_compute_type guid tmpl_guid plan_open_state",
        "RSRC": "rsrc_id parent_rsrc_id clndr_id role_id shift_id user_id pobs_id guid rsrc_seq_num email_addr employee_code office_phone other_phone rsrc_name rsrc_short_name rsrc_title_name def_qty_per_hr cost_qty_type ot_factor active_flag auto_compute_act_flag def_cost_qty_link_flag ot_flag curr_id unit_id rsrc_type location_id rsrc_notes load_tasks_flag level_flag last_checksum",
        "RSRCRATE": "rsrc_rate_id rsrc_id max_qty_per_hr cost_per_qty start_date shift_period_id cost_per_qty2 cost_per_qty3 cost_per_qty4 cost_per_qty5",
        "TASK": "task_id proj_id wbs_id clndr_id phys_complete_pct rev_fdbk_flag est_wt lock_plan_flag auto_compute_act_flag complete_pct_type task_type duration_type status_code task_code task_name rsrc_id total_float_hr_cnt free_float_hr_cnt remain_drtn_hr_cnt act_work_qty remain_work_qty target_work_qty target_drtn_hr_cnt target_equip_qty act_equip_qty remain_equip_qty cstr_date act_start_date act_end_date late_start_date late_end_date expect_end_date early_start_date early_end_date restart_date reend_date target_start_date target_end_date rem_late_start_date rem_late_end_date cstr_type priority_type suspend_date resume_date float_path float_path_order guid tmpl_guid cstr_date2 cstr_type2 driving_path_flag act_this_per_work_qty act_this_per_equip_qty external_early_start_date external_late_end_date create_date update_date create_user update_user location_id",
        "TASKPRED": "task_pred_id task_id pred_task_id proj_id pred_proj_id pred_type lag_hr_cnt comments float_path aref arls",
        "TASKRSRC": "taskrsrc_id task_id proj_id cost_qty_link_flag role_id acct_id rsrc_id pobs_id skill_level remain_qty target_qty remain_qty_per_hr target_lag_drtn_hr_cnt target_qty_per_hr act_ot_qty act_reg_qty relag_drtn_hr_cnt ot_factor cost_per_qty target_cost act_reg_cost act_ot_cost remain_cost act_start_date act_end_date restart_date reend_date target_start_date target_end_date rem_late_start_date rem_late_end_date rollup_dates_flag target_crv remain_crv actual_crv ts_pend_act_end_flag guid rate_type act_this_per_cost act_this_per_qty curv_id rsrc_type cost_per_qty_source_type create_user create_date has_rsrchours taskrsrc_sum_id",
    ].mapValues { $0.split(separator: " ").map(String.init) }

    /// P6's calendar text: weekly hours per day (1 = Sunday) and non-working exception days as Excel day numbers.
    static func calendarData(_ settings: CalendarSettings, day: WorkingDay, calendar: Calendar) -> String {
        var text = "(0||CalendarData()((0||DaysOfWeek()("
        for weekday in 1...7 {
            if settings.workingWeekdays.contains(weekday) {
                text += "(0||\(weekday)()("
                for (i, p) in day.periods.enumerated() {
                    text += "(0||\(i)(s|\(clock(p.from))|f|\(clock(p.to)))())"
                }
                text += "))"
            } else {
                text += "(0||\(weekday)()())"
            }
        }
        text += "))(0||VIEW(ShowTotal|Y)())(0||Exceptions()("
        let epoch = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        for (i, holiday) in settings.holidays.sorted().enumerated() {
            let serial = calendar.dateComponents([.day], from: epoch, to: calendar.startOfDay(for: holiday)).day ?? 0
            text += "(0||\(i)(d|\(serial))())"
        }
        return text + ")))"
    }

    // MARK: Import

    public static func `import`(_ data: Data) throws -> ImportResult {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        let tables = parseTables(text)
        guard let projects = tables["PROJECT"], !projects.isEmpty else { throw InterchangeError.malformed("there's no PROJECT table") }
        let calendar = Calendar.current
        var warnings: [String] = []

        let allTasks = tables["TASK"] ?? []
        // A file can hold several projects; take the one with the most activities.
        let source = projects.max { a, b in
            allTasks.count { $0["proj_id"] == a["proj_id"] } < allTasks.count { $0["proj_id"] == b["proj_id"] }
        }!
        let projID = source["proj_id"] ?? ""
        if projects.count > 1 { warnings.append("The file holds \(projects.count) projects; imported \(source["proj_short_name"] ?? projID).") }

        let wbsRows = (tables["PROJWBS"] ?? []).filter { $0["proj_id"] == projID }
        let projectNode = wbsRows.first { $0["proj_node_flag"] == "Y" }
        var project = Project(name: projectNode?["wbs_name"]?.nonEmpty ?? source["proj_short_name"] ?? "Imported Project")
        project.currencyCode = headerCurrency(text) ?? project.currencyCode
        if let start = DateText.parse(source["plan_start_date"]) ?? DateText.parse(source["last_recalc_date"]) {
            project.startDate = calendar.startOfDay(for: start)
        }

        let calendars = tables["CALENDAR"] ?? []
        let projectCalendar = calendars.first { $0["clndr_id"] == source["clndr_id"] }
            ?? calendars.first { $0["proj_id"] == projID && $0["default_flag"] == "Y" }
            ?? calendars.first { $0["default_flag"] == "Y" }
        let hoursPerDay = projectCalendar?["day_hr_cnt"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 8
        project.calendar = parseCalendar(projectCalendar?["clndr_data"], hoursPerDay: hoursPerDay, calendar: calendar)
        let day = WorkingDay(hours: hoursPerDay)

        // Outline: WBS elements become summary tasks with their activities underneath.
        let tasks = allTasks.filter { $0["proj_id"] == projID && $0["task_type"] != "TT_WBS" }
        let tasksByWBS = Dictionary(grouping: tasks) { $0["wbs_id"] ?? "" }
        let wbsChildren = Dictionary(grouping: wbsRows.filter { $0["proj_node_flag"] != "Y" }) { $0["parent_wbs_id"] ?? "" }
        func sortedWBS(_ parent: String) -> [[String: String]] {
            (wbsChildren[parent] ?? []).sorted {
                (Int($0["seq_num"] ?? "") ?? 0, $0["wbs_short_name"] ?? "") < (Int($1["seq_num"] ?? "") ?? 0, $1["wbs_short_name"] ?? "")
            }
        }
        func hasActivities(_ wbs: String) -> Bool {
            !(tasksByWBS[wbs] ?? []).isEmpty || sortedWBS(wbs).contains { hasActivities($0["wbs_id"] ?? "") }
        }

        var taskID: [String: UUID] = [:]
        var skippedConstraints = 0
        func addActivities(of wbs: String, level: Int) {
            let rows = (tasksByWBS[wbs] ?? []).sorted {
                ($0["early_start_date"] ?? $0["target_start_date"] ?? "", $0["task_code"] ?? "")
                    < ($1["early_start_date"] ?? $1["target_start_date"] ?? "", $1["task_code"] ?? "")
            }
            for row in rows {
                var task = ProjectTask(name: row["task_name"]?.nonEmpty ?? row["task_code"] ?? "Activity", outlineLevel: level)
                let milestone = row["task_type"] == "TT_Mile" || row["task_type"] == "TT_FinMile"
                let hoursValue = Double(row["target_drtn_hr_cnt"] ?? "") ?? Double(row["remain_drtn_hr_cnt"] ?? "") ?? 0
                task.duration = milestone ? 0 : max((hoursValue / hoursPerDay * 1000).rounded() / 1000, 0)
                task.percentComplete = row["status_code"] == "TK_Complete" ? 100 : Double(row["phys_complete_pct"] ?? "") ?? 0
                for (type, date) in [(row["cstr_type"], row["cstr_date"]), (row["cstr_type2"], row["cstr_date2"])] {
                    guard let type = type?.nonEmpty, let date = DateText.parse(date) else { continue }
                    switch type {
                    case "CS_MSO", "CS_MANDSTART":
                        task.constraint = .mustStartOn
                        task.constraintDate = day.startDay(date, calendar)
                    case "CS_MSOA": task.startAfter = day.startDay(date, calendar)
                    case "CS_MEOB", "CS_MEO", "CS_MANDFIN":
                        let d = day.finishDay(date, calendar)
                        task.finishBy = task.finishBy.map { min($0, d) } ?? d
                    default: skippedConstraints += 1
                    }
                }
                if let actual = DateText.parse(row["act_start_date"]), task.constraint != .mustStartOn {
                    task.startAfter = max(task.startAfter ?? .distantPast, day.startDay(actual, calendar))
                }
                if let id = row["task_id"] { taskID[id] = task.id }
                project.tasks.append(task)
            }
        }
        func addWBS(_ parent: String, level: Int) {
            for node in sortedWBS(parent) {
                let id = node["wbs_id"] ?? ""
                guard hasActivities(id) else { continue }
                project.tasks.append(ProjectTask(name: node["wbs_name"]?.nonEmpty ?? node["wbs_short_name"] ?? "WBS", outlineLevel: level))
                addActivities(of: id, level: level + 1)
                addWBS(id, level: level + 1)
            }
        }
        let rootID = projectNode?["wbs_id"] ?? ""
        addActivities(of: rootID, level: 1)
        addWBS(rootID, level: 1)
        // Activities whose WBS wasn't in the file.
        let known = Set(wbsRows.compactMap { $0["wbs_id"] })
        for wbs in tasksByWBS.keys.sorted() where !known.contains(wbs) { addActivities(of: wbs, level: 1) }
        if skippedConstraints > 0 {
            warnings.append("\(skippedConstraints) constraint(s) other than Start On, Start On or After and Finish On or Before were dropped.")
        }

        var external = 0
        for row in tables["TASKPRED"] ?? [] {
            guard let s = row["task_id"].flatMap({ taskID[$0] }) else { continue }
            guard let p = row["pred_task_id"].flatMap({ taskID[$0] }) else { external += 1; continue }
            let type = DependencyType(rawValue: String((row["pred_type"] ?? "PR_FS").dropFirst(3))) ?? .finishToStart
            let lag = (Double(row["lag_hr_cnt"] ?? "") ?? 0) / hoursPerDay
            project.dependencies.append(Dependency(predecessorID: p, successorID: s, type: type, lag: (lag * 1000).rounded() / 1000))
        }
        if external > 0 { warnings.append("\(external) link(s) to activities in other projects were skipped.") }

        // Resources assigned in this project; a resource's parent (or title) becomes its group.
        let assignments = (tables["TASKRSRC"] ?? []).filter { $0["task_id"].flatMap { taskID[$0] } != nil }
        let rsrcRows = tables["RSRC"] ?? []
        let rsrcByID = Dictionary(rsrcRows.compactMap { r in r["rsrc_id"].map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let rates = Dictionary(grouping: tables["RSRCRATE"] ?? []) { $0["rsrc_id"] ?? "" }
        var resourceID: [String: UUID] = [:]
        var materials = 0
        for id in assignments.compactMap({ $0["rsrc_id"] }) where resourceID[id] == nil {
            guard let r = rsrcByID[id] else { continue }
            if r["rsrc_type"] == "RT_Mat" { materials += 1; continue }
            let rate = (rates[id] ?? []).sorted { ($0["start_date"] ?? "") < ($1["start_date"] ?? "") }.last
            let resource = Resource(
                name: r["rsrc_name"]?.nonEmpty ?? r["rsrc_short_name"] ?? "Resource", initials: r["rsrc_short_name"]?.nonEmpty,
                group: r["parent_rsrc_id"].flatMap { rsrcByID[$0]?["rsrc_name"] } ?? r["rsrc_title_name"] ?? "",
                maxUnits: rate?["max_qty_per_hr"].flatMap(Double.init) ?? r["def_qty_per_hr"].flatMap(Double.init) ?? 1,
                standardRate: rate?["cost_per_qty"].flatMap(Double.init) ?? 0,
                email: r["email_addr"] ?? "")
            resourceID[id] = resource.id
            project.resources.append(resource)
        }
        if materials > 0 { warnings.append("\(materials) material resource(s) were skipped.") }
        for row in assignments {
            guard let t = row["task_id"].flatMap({ taskID[$0] }), let r = row["rsrc_id"].flatMap({ resourceID[$0] }) else { continue }
            var units = Double(row["target_qty_per_hr"] ?? "") ?? 0
            if units <= 0, let qty = Double(row["target_qty"] ?? ""), let task = project.task(t), task.duration > 0 {
                units = qty / (task.duration * hoursPerDay)
            }
            project.assignments.append(Assignment(taskID: t, resourceID: r, units: units > 0 ? units : 1))
        }
        return ImportResult(project: project, warnings: warnings)
    }

    // MARK: Helpers

    /// Rows of each table as field-name dictionaries.
    static func parseTables(_ text: String) -> [String: [[String: String]]] {
        var tables: [String: [[String: String]]] = [:]
        var table = "", fields: [String] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch parts.first {
            case "%T": table = parts.count > 1 ? parts[1] : ""; fields = []; tables[table, default: []] = []
            case "%F": fields = Array(parts.dropFirst())
            case "%R":
                var row: [String: String] = [:]
                for (field, value) in zip(fields, parts.dropFirst()) { row[field] = value }
                tables[table, default: []].append(row)
            default: break
            }
        }
        return tables
    }

    private static func headerCurrency(_ text: String) -> String? {
        guard let header = text.split(whereSeparator: \.isNewline).first, header.hasPrefix("ERMHDR") else { return nil }
        let parts = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count > 8 else { return nil }
        let code = parts[8].trimmingCharacters(in: .whitespacesAndNewlines)
        return code.count == 3 ? code : nil
    }

    /// Working weekdays and whole non-working exception days from `clndr_data`.
    static func parseCalendar(_ data: String?, hoursPerDay: Double, calendar: Calendar) -> CalendarSettings {
        var settings = CalendarSettings(hoursPerDay: hoursPerDay)
        guard let data, let daysRange = data.range(of: "DaysOfWeek()") else { return settings }
        let exceptionsRange = data.range(of: "Exceptions()")
        let weekText = data[daysRange.upperBound..<(data.range(of: "VIEW", range: daysRange.upperBound..<data.endIndex)?.lowerBound
            ?? exceptionsRange?.lowerBound ?? data.endIndex)]
        // Each day is "(0||<weekday>()(<hours>))"; a working day has "s|" before the next day starts.
        let week = weekText.replacingOccurrences(of: "\u{7F}", with: "")
        let days = week.matches(of: /\(0\|\|([1-7])\(\)/)
        var weekdays: Set<Int> = []
        for (i, match) in days.enumerated() {
            let end = i + 1 < days.count ? days[i + 1].range.lowerBound : week.endIndex
            if week[match.range.upperBound..<end].contains("s|"), let n = Int(match.1) { weekdays.insert(n) }
        }
        if !days.isEmpty { settings.workingWeekdays = weekdays }

        if let exceptionsRange {
            let epoch = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
            // Exceptions with hours are working days; only empty ones are holidays: "(0||n(d|45000)())".
            let pattern = /\(d\|(\d+)\)\s*\(\)/
            for match in data[exceptionsRange.upperBound...].replacingOccurrences(of: "\u{7F}", with: "").matches(of: pattern) {
                if let serial = Int(match.1), let date = calendar.date(byAdding: .day, value: serial, to: epoch) {
                    settings.holidays.append(date)
                }
            }
            settings.holidays.sort()
        }
        return settings
    }

    /// A P6 project ID: letters and digits from the name, at most 20 characters.
    static func projectShortName(_ name: String) -> String {
        let letters = name.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return letters.isEmpty ? "PROJECT" : String(letters.prefix(20))
    }

    /// XER values can't hold tabs or line breaks.
    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ").components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func clock(_ hour: Double) -> String {
        let minutes = Int((hour * 60).rounded())
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
