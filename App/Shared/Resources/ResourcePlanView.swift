import SwiftUI
import ProjectorKit

/// What each cell of the resource plan shows.
enum UsageValue: String, CaseIterable, Identifiable {
    case hours, percent, fte

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hours: "Work (hours)"
        case .percent: "Allocation (% of capacity)"
        case .fte: "FTE"
        }
    }
}

/// The resource plan as a spreadsheet, like MS Project's Resource Usage view: one row per resource with
/// its assignments underneath, one column per day / week / month, work in each cell, overallocation in red.
struct ResourcePlanView: View {
    @Bindable var controller: ProjectController
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var leftWidth: CGFloat = 0

    enum Row: Hashable {
        case resource(UUID)
        case assignment(UUID)
        case total
    }

    private var rowHeight: CGFloat {
        #if os(macOS)
        24
        #else
        34
        #endif
    }

    var body: some View {
        let compact = sizeClass == .compact
        if controller.project.resources.isEmpty {
            ContentUnavailableView {
                Label("No Resources", systemImage: "person.2")
            } description: {
                Text("Add people to the project, then assign them to tasks to see their work per week.")
            } actions: {
                Button("Add Resource") { controller.addResource() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            let grid = UsageGrid(controller: controller)
            GeometryReader { geometry in
            TimelineSplitView(
                rowCount: grid.rows.count, rowHeight: rowHeight, contentWidth: grid.contentWidth, leftWidth: $leftWidth,
                leftHeader: { UsageLeftHeader(compact: compact, value: controller.usageValue) },
                leftRow: { index in leftRow(grid.rows[index], grid: grid, compact: compact) },
                chartHeader: { offsetX in UsageHeader(grid: grid, offsetX: offsetX) },
                drawChart: { context, rect in grid.draw(in: &context, rect: rect, rowHeight: rowHeight) },
                onChartTap: { _, index in
                    guard grid.rows.indices.contains(index) else { return }
                    select(grid.rows[index])
                }
            )
            .onChange(of: geometry.size.width, initial: true) { _, width in
                guard width > 0 else { return }
                leftWidth = compact ? width * 0.56 : min(380, width * 0.4)
            }
            }
        }
    }

    private func select(_ row: Row) {
        switch row {
        case .resource(let id):
            controller.resourceSelection = [id]
        case .assignment(let id):
            if let a = controller.project.assignments.first(where: { $0.id == id }) {
                controller.resourceSelection = [a.resourceID]
                controller.select(a.taskID)
            }
        case .total:
            break
        }
    }

    @ViewBuilder
    private func leftRow(_ row: Row, grid: UsageGrid, compact: Bool) -> some View {
        let project = controller.project
        Group {
            switch row {
            case .resource(let id):
                if let r = project.resource(id) {
                    let load = controller.schedule.resourceLoads[id] ?? ResourceLoad()
                    HStack(spacing: 4) {
                        Button {
                            if controller.collapsedResources.contains(id) { controller.collapsedResources.remove(id) }
                            else { controller.collapsedResources.insert(id) }
                        } label: {
                            Image(systemName: controller.collapsedResources.contains(id) ? "chevron.right" : "chevron.down")
                                .font(.caption2.weight(.bold)).frame(width: 14, height: 14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        Circle().fill(ResourcePalette.color(for: id, in: project)).frame(width: 8, height: 8)
                        Text(r.name).fontWeight(.semibold)
                        if load.isOverallocated {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                                .help("Overallocated on \(load.overallocatedDays.count) day(s)")
                        }
                        Spacer(minLength: 4)
                        if !compact {
                            Text(Notation.formatPercent(r.maxUnits)).foregroundStyle(.secondary)
                                .frame(width: UsageLeftHeader.maxWidth, alignment: .trailing)
                        }
                        Text(grid.format(grid.total(of: row))).monospacedDigit()
                            .frame(width: UsageLeftHeader.totalWidth, alignment: .trailing)
                    }
                    .background(controller.resourceSelection.contains(id) ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.07))
                }
            case .assignment(let id):
                if let a = project.assignments.first(where: { $0.id == id }), let task = project.task(a.taskID) {
                    HStack(spacing: 4) {
                        Text(task.name)
                        Spacer(minLength: 4)
                        if !compact {
                            Text(Notation.formatPercent(a.units)).foregroundStyle(.secondary)
                                .frame(width: UsageLeftHeader.maxWidth, alignment: .trailing)
                        }
                        Text(grid.format(grid.total(of: row))).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: UsageLeftHeader.totalWidth, alignment: .trailing)
                    }
                    .font(compact ? .footnote : GanttRow.font)
                    .padding(.leading, compact ? 14 : 24)
                    .background(controller.selection.contains(task.id) ? Color.accentColor.opacity(0.12) : .clear)
                }
            case .total:
                HStack {
                    Text("Total").fontWeight(.bold)
                    Spacer()
                    Text(grid.format(grid.total(of: row))).fontWeight(.bold).monospacedDigit()
                        .frame(width: UsageLeftHeader.totalWidth, alignment: .trailing)
                }
                .background(Color.secondary.opacity(0.12))
            }
        }
        .font(GanttRow.font)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator.opacity(0.6)).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture { select(row) }
    }
}

private struct UsageLeftHeader: View {
    let compact: Bool
    let value: UsageValue
    static let maxWidth: CGFloat = 52
    static let totalWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: 4) {
            Text("Resource / Task").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
            if !compact {
                Text("Units").frame(width: Self.maxWidth, alignment: .trailing)
            }
            Text(value == .hours ? "Work" : value == .percent ? "Avg %" : "Avg FTE")
                .frame(width: Self.totalWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 16)
    }
}

/// Rows, columns and cell values of the resource plan.
@MainActor
struct UsageGrid {
    let project: Project
    let schedule: Schedule
    let periods: [TimePeriod]
    let timescale: Timescale
    let value: UsageValue
    let rows: [ResourcePlanView.Row]
    let columnWidth: CGFloat

    init(controller: ProjectController) {
        project = controller.project
        schedule = controller.schedule
        timescale = controller.usageTimescale
        value = controller.usageValue
        periods = schedule.periods(timescale)
        columnWidth = switch timescale {
        case .day: 48
        case .week: 64
        case .month: 76
        }
        let byResource = Dictionary(grouping: project.assignments, by: \.resourceID)
        let schedule = schedule
        rows = project.resources.flatMap { r -> [ResourcePlanView.Row] in
            let assignments = controller.collapsedResources.contains(r.id) ? [] :
                (byResource[r.id] ?? [])
                    .sorted { (schedule[$0.taskID]?.earlyStart ?? 0) < (schedule[$1.taskID]?.earlyStart ?? 0) }
                    .map { ResourcePlanView.Row.assignment($0.id) }
            return [.resource(r.id)] + assignments
        } + [.total]
    }

    var contentWidth: CGFloat { CGFloat(periods.count) * columnWidth }

    private func assignment(_ id: UUID) -> Assignment? { project.assignments.first { $0.id == id } }

    /// (work hours, capacity hours at the relevant units) for a cell.
    func cell(_ row: ResourcePlanView.Row, _ period: TimePeriod) -> (work: Double, capacity: Double) {
        switch row {
        case .resource(let id):
            guard let r = project.resource(id) else { return (0, 0) }
            return (schedule.work(ofResource: id, in: period), schedule.capacity(of: r, in: period))
        case .assignment(let id):
            guard let a = assignment(id), let r = project.resource(a.resourceID) else { return (0, 0) }
            return (schedule.work(of: a, in: period), schedule.capacity(of: r, in: period))
        case .total:
            let work = project.resources.reduce(0) { $0 + schedule.work(ofResource: $1.id, in: period) }
            let capacity = project.resources.reduce(0) { $0 + schedule.capacity(of: $1, in: period) }
            return (work, capacity)
        }
    }

    /// The figure shown in a cell, or nil for an empty cell.
    func display(_ row: ResourcePlanView.Row, _ period: TimePeriod) -> Double? {
        let (work, capacity) = cell(row, period)
        guard work > 1e-9 else { return nil }
        switch value {
        case .hours: return work
        case .percent: return capacity > 0 ? work / capacity * 100 : nil
        case .fte:
            let fullTime = Double(period.workingDayCount) * project.calendar.hoursPerDay
            return fullTime > 0 ? work / fullTime : nil
        }
    }

    /// The row total: hours summed, or the average over the periods with work.
    func total(of row: ResourcePlanView.Row) -> Double {
        let cells = periods.map { cell(row, $0) }
        let work = cells.reduce(0) { $0 + $1.work }
        switch value {
        case .hours: return work
        case .percent:
            let active = cells.filter { $0.work > 1e-9 }
            let capacity = active.reduce(0) { $0 + $1.capacity }
            return capacity > 0 ? work / capacity * 100 : 0
        case .fte:
            let activePeriods = zip(periods, cells).filter { $0.1.work > 1e-9 }
            let fullTime = activePeriods.reduce(0) { $0 + Double($1.0.workingDayCount) } * project.calendar.hoursPerDay
            return fullTime > 0 ? work / fullTime : 0
        }
    }

    func isOver(_ row: ResourcePlanView.Row, _ period: TimePeriod) -> Bool {
        switch row {
        case .resource(let id):
            return project.resource(id).map { schedule.isOverallocated($0, in: period) } ?? false
        case .assignment(let id):
            guard let a = assignment(id), let r = project.resource(a.resourceID) else { return false }
            return schedule.isOverallocated(r, in: period) && schedule.work(of: a, in: period) > 1e-9
        case .total:
            return false
        }
    }

    func format(_ number: Double) -> String {
        switch value {
        case .hours: return Notation.formatNumber(number.rounded(toPlaces: 1)) + "h"
        case .percent: return "\(Int(number.rounded()))%"
        case .fte: return String(format: "%.2f", number)
        }
    }

    func label(for period: TimePeriod) -> String {
        switch timescale {
        case .day: period.start.formatted(.dateTime.weekday(.narrow).day())
        case .week: period.start.formatted(.dateTime.day().month(.abbreviated))
        case .month: period.start.formatted(.dateTime.month(.abbreviated))
        }
    }

    func groupLabel(for period: TimePeriod) -> String {
        switch timescale {
        case .day:
            "Week of " + (schedule.calendar.calendar.dateInterval(of: .weekOfYear, for: period.start)?.start ?? period.start)
                .formatted(.dateTime.day().month(.abbreviated).year())
        case .week: period.start.formatted(.dateTime.month(.wide).year())
        case .month: period.start.formatted(.dateTime.year())
        }
    }

    func draw(in context: inout GraphicsContext, rect: CGRect, rowHeight: CGFloat) {
        guard !periods.isEmpty, !rows.isEmpty else { return }
        let firstCol = max(Int(rect.minX / columnWidth), 0)
        let lastCol = min(Int(rect.maxX / columnWidth), periods.count - 1)
        let firstRow = max(Int(rect.minY / rowHeight), 0)
        let lastRow = min(Int(rect.maxY / rowHeight), rows.count - 1)
        guard firstCol <= lastCol, firstRow <= lastRow else { return }

        var grid = Path()
        for row in firstRow...lastRow {
            let y = CGFloat(row) * rowHeight
            let r = rows[row]
            switch r {
            case .resource: context.fill(Path(CGRect(x: rect.minX, y: y, width: rect.width, height: rowHeight)), with: .color(.secondary.opacity(0.07)))
            case .total: context.fill(Path(CGRect(x: rect.minX, y: y, width: rect.width, height: rowHeight)), with: .color(.secondary.opacity(0.12)))
            case .assignment: break
            }
            for col in firstCol...lastCol {
                let period = periods[col]
                let cellRect = CGRect(x: CGFloat(col) * columnWidth, y: y, width: columnWidth, height: rowHeight)
                if period.workingDayCount == 0 {
                    context.fill(Path(cellRect), with: .color(.secondary.opacity(0.1)))
                    continue
                }
                let over = isOver(r, period)
                if over {
                    context.fill(Path(cellRect), with: .color(GanttRenderer.criticalColor.opacity(r == .total ? 0 : 0.16)))
                }
                guard let number = display(r, period) else { continue }
                let weight: Font.Weight = {
                    if case .assignment = r { return .regular }
                    return .semibold
                }()
                var text = Text(format(number)).font(.system(size: 11, weight: weight)).monospacedDigit()
                if over { text = text.foregroundStyle(GanttRenderer.criticalColor) }
                else if case .assignment = r { text = text.foregroundStyle(.secondary) }
                context.draw(text, at: CGPoint(x: cellRect.maxX - 6, y: cellRect.midY), anchor: .trailing)
            }
            grid.move(to: CGPoint(x: rect.minX, y: y + rowHeight - 0.5))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y + rowHeight - 0.5))
        }
        for col in firstCol...(lastCol + 1) {
            let x = CGFloat(col) * columnWidth - 0.5
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
    }

    /// Tab-separated copy of the grid that pastes straight into Excel or Numbers.
    func tabSeparated() -> String {
        var lines = [(["Resource", "Task", "Units", "Total"] + periods.map { $0.start.formatted(date: .numeric, time: .omitted) })
            .joined(separator: "\t")]
        for row in rows {
            var cells: [String]
            switch row {
            case .resource(let id):
                let r = project.resource(id)
                cells = [r?.name ?? "", "", r.map { Notation.formatPercent($0.maxUnits) } ?? ""]
            case .assignment(let id):
                let a = assignment(id)
                cells = [a.flatMap { project.resource($0.resourceID)?.name } ?? "",
                         a.flatMap { project.task($0.taskID)?.name } ?? "",
                         a.map { Notation.formatPercent($0.units) } ?? ""]
            case .total:
                cells = ["Total", "", ""]
            }
            cells.append(raw(total(of: row)))
            cells += periods.map { display(row, $0).map(raw) ?? "" }
            lines.append(cells.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private func raw(_ number: Double) -> String {
        value == .fte ? String(format: "%.2f", number) : Notation.formatNumber(number.rounded(toPlaces: 1))
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}

/// Two-tier header for the resource plan columns (e.g. months over weeks).
private struct UsageHeader: View {
    let grid: UsageGrid
    let offsetX: CGFloat

    var body: some View {
        Canvas { context, size in
            let half = size.height / 2
            let w = grid.columnWidth
            let first = max(Int(offsetX / w), 0)
            let last = min(Int((offsetX + size.width) / w), grid.periods.count - 1)
            guard first <= last else { return }
            var lines = Path()
            // Group tier: label each run of periods sharing a group, pinned to the visible left edge.
            var runStart = first
            for col in first...last + 1 {
                let ended = col > last || grid.groupLabel(for: grid.periods[col]) != grid.groupLabel(for: grid.periods[runStart])
                guard ended else { continue }
                let x0 = CGFloat(runStart) * w - offsetX
                let x1 = CGFloat(col) * w - offsetX
                let resolved = context.resolve(Text(grid.groupLabel(for: grid.periods[runStart]))
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary))
                let textWidth = resolved.measure(in: CGSize(width: 400, height: half)).width
                if textWidth + 8 <= x1 - max(x0, 0) {
                    context.draw(resolved, at: CGPoint(x: max(x0, 0) + 4, y: half / 2), anchor: .leading)
                }
                lines.move(to: CGPoint(x: x1 - 0.5, y: 0))
                lines.addLine(to: CGPoint(x: x1 - 0.5, y: half))
                runStart = col
            }
            for col in first...last {
                let x = CGFloat(col) * w - offsetX
                let text = Text(grid.label(for: grid.periods[col])).font(.system(size: 10.5)).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: x + w - 6, y: half + half / 2), anchor: .trailing)
                lines.move(to: CGPoint(x: x + w - 0.5, y: half))
                lines.addLine(to: CGPoint(x: x + w - 0.5, y: size.height))
            }
            lines.move(to: CGPoint(x: 0, y: half))
            lines.addLine(to: CGPoint(x: size.width, y: half))
            lines.move(to: CGPoint(x: 0, y: size.height - 0.5))
            lines.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(lines, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
        }
        .background(.bar)
    }
}

enum ResourcePalette {
    static let colors: [Color] = [
        Color(red: 0.25, green: 0.47, blue: 0.85), Color(red: 0.18, green: 0.62, blue: 0.45),
        Color(red: 0.85, green: 0.55, blue: 0.13), Color(red: 0.55, green: 0.36, blue: 0.82),
        Color(red: 0.12, green: 0.6, blue: 0.7), Color(red: 0.8, green: 0.35, blue: 0.55),
        Color(red: 0.45, green: 0.5, blue: 0.2), Color(red: 0.4, green: 0.4, blue: 0.45),
    ]

    static func color(for id: UUID, in project: Project) -> Color {
        let index = project.resources.firstIndex { $0.id == id } ?? 0
        return colors[index % colors.count]
    }
}
