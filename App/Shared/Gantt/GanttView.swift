import SwiftUI
import ProjectorKit

struct GanttView: View {
    @Bindable var controller: ProjectController
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var leftWidth: CGFloat = 0
    @State private var sizedForWidth: CGFloat = 0
    @State private var drag: GanttDrag?

    private var compact: Bool { sizeClass == .compact }
    private var rowHeight: CGFloat {
        #if os(macOS)
        24
        #else
        compact ? 38 : 34
        #endif
    }

    var body: some View {
        let schedule = controller.schedule
        let rows = controller.visibleTaskIDs
        let scale = TimelineScale(schedule: schedule, pixelsPerDay: controller.pixelsPerDay)
        let columns = GanttColumns(compact: compact)

        GeometryReader { geometry in
            if controller.project.tasks.isEmpty {
                EmptyProjectView(controller: controller)
            } else {
                TimelineSplitView(
                    rowCount: rows.count, rowHeight: rowHeight, contentWidth: scale.width, leftWidth: $leftWidth,
                    leftHeader: { GanttHeaderRow(columns: columns) },
                    leftRow: { index in
                        GanttRow(controller: controller, taskID: rows[index], columns: columns, editable: !compact)
                    },
                    chartHeader: { offsetX in TimelineHeader(scale: scale, offsetX: offsetX) },
                    drawChart: { context, rect in
                        GanttRenderer(controller: controller, rows: rows, scale: scale, rowHeight: rowHeight, drag: drag)
                            .draw(in: &context, rect: rect)
                    },
                    onChartTap: { _, row in
                        guard rows.indices.contains(row) else { controller.selection = []; return }
                        controller.select(rows[row], extend: Modifiers.shift, toggle: Modifiers.command)
                        if compact { controller.showInspector = true }
                    },
                    onChartDrag: ChartDragHandler(
                        changed: { start, dx in
                            if drag == nil {
                                drag = GanttRenderer(controller: controller, rows: rows, scale: scale, rowHeight: rowHeight, drag: nil)
                                    .hitTest(start)
                            }
                            drag?.dx = dx
                        },
                        ended: { _, dx in
                            defer { drag = nil }
                            guard let drag else { return }
                            commit(drag, dx: dx, scale: scale)
                        }),
                    initialX: scale.x(for: schedule.projectStart) - scale.pixelsPerDay * 2,
                    zoom: scale.pixelsPerDay
                )
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    // Re-fit on first layout and on rotation / window resizes; keep manual drags otherwise.
                    guard width > 0, abs(width - sizedForWidth) > 1 else { return }
                    sizedForWidth = width
                    leftWidth = columns.preferredWidth(available: width)
                }
                .onChange(of: compact) { leftWidth = columns.preferredWidth(available: geometry.size.width) }
            }
        }
    }

    private func commit(_ drag: GanttDrag, dx: CGFloat, scale: TimelineScale) {
        guard let s = controller.schedule[drag.taskID] else { return }
        switch drag.kind {
        case .move:
            let x = (s.isMilestone ? scale.milestoneX(s.earlyStart) : scale.startX(s.earlyStart)) + dx
            controller.moveTask(drag.taskID, toStart: scale.date(atX: x + scale.pixelsPerDay / 2))
        case .resize:
            let x = scale.finishX(s.earlyFinish) + dx
            controller.resizeTask(drag.taskID, toFinish: scale.date(atX: x - scale.pixelsPerDay / 2))
        }
    }
}

/// Modifier keys at the moment of a click (macOS); always false elsewhere.
enum Modifiers {
    static var shift: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }
    static var command: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }
}

struct EmptyProjectView: View {
    let controller: ProjectController

    var body: some View {
        ContentUnavailableView {
            Label("No Tasks Yet", systemImage: "chart.bar.doc.horizontal")
        } description: {
            Text("Add tasks one by one, jot a whole plan down as text, or start from the sample project.")
        } actions: {
            Button("Add Task") { controller.addTask() }
                .buttonStyle(.borderedProminent)
            Button("Quick Plan…") { controller.showQuickPlan = true }
            Button("Load Sample Project") { controller.loadSample() }
        }
    }
}

// MARK: - Table side

struct GanttColumns {
    let compact: Bool

    var showDetails: Bool { !compact }
    let indicator: CGFloat = 20
    let id: CGFloat = 34
    let wbs: CGFloat = 44
    #if os(macOS)
    let name: CGFloat = 220
    let duration: CGFloat = 68
    let date: CGFloat = 96
    let predecessors: CGFloat = 92
    let resources: CGFloat = 150
    #else
    let name: CGFloat = 230
    let duration: CGFloat = 76
    let date: CGFloat = 112
    let predecessors: CGFloat = 108
    let resources: CGFloat = 160
    #endif
    /// Compact (iPhone) duration column, showing "5d".
    let compactDuration: CGFloat = 44

    var fullWidth: CGFloat {
        indicator + id + wbs + name + duration + date * 2 + predecessors + resources
    }

    /// The whole table when there's room, otherwise half the window (the grid can be widened by dragging).
    func preferredWidth(available: CGFloat) -> CGFloat {
        compact ? min(230, available * 0.52) : min(fullWidth, max(available * 0.5, 360))
    }
}

struct GanttHeaderRow: View {
    let columns: GanttColumns

    var body: some View {
        HStack(spacing: 0) {
            if columns.showDetails {
                cell("", columns.indicator)
                cell("ID", columns.id, alignment: .trailing)
                cell("WBS", columns.wbs)
            }
            cell("Task Name", columns.compact ? nil : columns.name)
            cell(columns.compact ? "Dur." : "Duration", columns.compact ? columns.compactDuration : columns.duration)
            if columns.showDetails {
                cell("Start", columns.date)
                cell("Finish", columns.date)
                cell("Predecessors", columns.predecessors)
                cell("Resources", columns.resources)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 16)
    }

    private func cell(_ title: String, _ width: CGFloat?, alignment: Alignment = .leading) -> some View {
        Text(title)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}

struct GanttRow: View {
    let controller: ProjectController
    let taskID: UUID
    let columns: GanttColumns
    let editable: Bool

    var body: some View {
        let project = controller.project
        let schedule = controller.schedule
        if let task = project.task(taskID), let s = schedule[taskID] {
            let outline = schedule.outline
            let isSelected = controller.selection.contains(taskID)
            HStack(spacing: 0) {
                if columns.showDetails {
                    indicators(task: task, s: s)
                        .frame(width: columns.indicator)
                    Text("\((outline.rowIndex[taskID] ?? 0) + 1)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .frame(width: columns.id, alignment: .trailing)
                    Text(outline.wbs[taskID] ?? "")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .frame(width: columns.wbs, alignment: .leading)
                }
                nameCell(task: task, s: s, outline: outline)
                    .frame(width: columns.compact ? nil : columns.name, alignment: .leading)
                    .frame(maxWidth: columns.compact ? .infinity : nil, alignment: .leading)
                durationCell(task: task, s: s)
                    .frame(width: columns.compact ? columns.compactDuration : columns.duration, alignment: .leading)
                if columns.showDetails {
                    Text(s.start, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .padding(.horizontal, 4)
                        .frame(width: columns.date, alignment: .leading)
                    Text(s.finish, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .padding(.horizontal, 4)
                        .frame(width: columns.date, alignment: .leading)
                    textCell(Notation.formatPredecessors(of: taskID, in: project, outline: outline),
                             width: columns.predecessors) { controller.setPredecessors(taskID, text: $0) }
                    textCell(Notation.formatResources(of: taskID, in: project),
                             width: columns.resources, enabled: !s.isSummary) { controller.setResources(taskID, text: $0) }
                }
            }
            .font(s.isSummary ? Self.font.weight(.semibold) : Self.font)
            .lineLimit(1)
            .frame(maxHeight: .infinity)
            .frame(minWidth: columns.compact ? 0 : columns.fullWidth, maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5) }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                controller.select(taskID, extend: Modifiers.shift, toggle: Modifiers.command)
                if !editable { controller.showInspector = true }
            })
            .contextMenu { TaskContextMenu(controller: controller, taskID: taskID) }
        }
    }

    static var font: Font {
        #if os(macOS)
        .callout
        #else
        .subheadline
        #endif
    }

    private func indicators(task: ProjectTask, s: ScheduledTask) -> some View {
        ZStack {
            if controller.schedule.cycleTaskIDs.contains(taskID) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("This task is part of a circular dependency.")
            } else if s.missesDeadline {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(GanttRenderer.criticalColor)
                    .help(s.isSummary ? "A subtask misses its deadline" : "Misses its deadline")
            } else if task.constraint == .mustStartOn {
                Image(systemName: "pin.fill").foregroundStyle(.secondary)
                    .help(task.constraint.title)
            } else if task.earliestStart != nil || task.finishBy != nil {
                Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
                    .help(dateLimitHelp(task))
            } else if task.levelingDelay > 0 {
                Image(systemName: "arrow.right.to.line").foregroundStyle(.purple)
                    .help("Delayed \(Notation.formatDuration(task.levelingDelay)) by leveling")
            } else if !task.notes.isEmpty {
                Image(systemName: "note.text").foregroundStyle(.secondary)
                    .help(task.notes)
            } else if s.percentComplete >= 100 {
                Image(systemName: "checkmark").foregroundStyle(.green)
            }
        }
        .font(.caption2)
        .frame(width: columns.indicator)
        .clipped()
    }

    private func dateLimitHelp(_ task: ProjectTask) -> String {
        var parts: [String] = []
        if let d = task.earliestStart { parts.append("Starts after \(d.formatted(date: .abbreviated, time: .omitted))") }
        if let d = task.finishBy { parts.append("Finish by \(d.formatted(date: .abbreviated, time: .omitted))") }
        return parts.joined(separator: " · ")
    }

    private func nameCell(task: ProjectTask, s: ScheduledTask, outline: Outline) -> some View {
        let depth = CGFloat((outline.level[taskID] ?? 1) - 1)
        return HStack(spacing: 2) {
            if s.isSummary {
                Button {
                    controller.toggleCollapsed(taskID)
                } label: {
                    Image(systemName: controller.collapsed.contains(taskID) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Spacer().frame(width: 14)
            }
            if s.isMilestone {
                Image(systemName: "diamond.fill").font(.caption2).foregroundStyle(.secondary)
            }
            if editable {
                CommitTextField(value: task.name, placeholder: "Task name") { name in
                    controller.updateTask(taskID, "Rename Task") { $0.name = name }
                }
            } else {
                Text(task.name)
            }
        }
        .padding(.leading, 2 + depth * 14)
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private func durationCell(task: ProjectTask, s: ScheduledTask) -> some View {
        let text = columns.compact ? Notation.formatNumber(s.duration) + "d" : Notation.formatDuration(s.duration)
        if editable && !s.isSummary {
            CommitTextField(value: text, placeholder: "") { controller.setDuration(taskID, text: $0) }
                .padding(.horizontal, 4)
        } else {
            Text(text).padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func textCell(_ value: String, width: CGFloat, enabled: Bool = true, commit: @escaping (String) -> Void) -> some View {
        Group {
            if editable && enabled {
                CommitTextField(value: value, placeholder: "", onCommit: commit)
            } else {
                Text(value)
            }
        }
        .padding(.horizontal, 4)
        .frame(width: width, alignment: .leading)
    }
}

struct TaskContextMenu: View {
    let controller: ProjectController
    let taskID: UUID

    var body: some View {
        Button("Insert Task", systemImage: "plus") { prepare(); controller.addTask() }
        Button("Insert Milestone", systemImage: "diamond") { prepare(); controller.addTask(milestone: true) }
        Divider()
        Button("Indent", systemImage: "increase.indent") { prepare(); controller.indent() }
        Button("Outdent", systemImage: "decrease.indent") { prepare(); controller.outdent() }
        Button("Move Up", systemImage: "arrow.up") { prepare(); controller.moveUp() }
        Button("Move Down", systemImage: "arrow.down") { prepare(); controller.moveDown() }
        Divider()
        if controller.selection.count > 1 && controller.selection.contains(taskID) {
            Button("Link Selected Tasks", systemImage: "link") { controller.linkSelection() }
        }
        Button("Unlink", systemImage: "link.badge.plus") { prepare(); controller.unlinkSelection() }
        Button("Task Information…", systemImage: "info.circle") { prepare(); controller.showInspector = true }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { prepare(); controller.deleteSelection() }
    }

    /// Context-clicking a row outside the selection acts on that row alone.
    private func prepare() {
        if !controller.selection.contains(taskID) { controller.select(taskID) }
    }
}
