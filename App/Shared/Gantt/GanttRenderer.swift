import SwiftUI
import ProjectorKit

extension Color {
    static var chartBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

struct GanttDrag {
    enum Kind { case move, resize }
    var taskID: UUID
    var kind: Kind
    var dx: CGFloat = 0
}

/// Draws the Gantt chart: bars, summaries, milestones, baselines, links and the critical path.
@MainActor
struct GanttRenderer {
    let controller: ProjectController
    let rows: [UUID]
    let scale: TimelineScale
    let rowHeight: CGFloat
    let drag: GanttDrag?

    private var schedule: Schedule { controller.schedule }
    private var barHeight: CGFloat { max(rowHeight * 0.42, 9) }
    private var hasBaseline: Bool { controller.showBaseline && controller.project.tasks.contains { $0.baselineStart != nil } }

    static let taskColor = Color(red: 0.25, green: 0.47, blue: 0.85)
    static let criticalColor = Color(red: 0.86, green: 0.2, blue: 0.2)

    private func color(for s: ScheduledTask) -> Color {
        controller.showCriticalPath && s.isCritical ? Self.criticalColor : Self.taskColor
    }

    private func barY(row: Int) -> CGFloat {
        CGFloat(row) * rowHeight + (rowHeight - barHeight) / 2 - (hasBaseline ? 3 : 0)
    }

    /// Horizontal extent of a task's bar, including any in-progress drag.
    private func barSpan(_ id: UUID, _ s: ScheduledTask) -> (CGFloat, CGFloat) {
        var x0 = s.isMilestone ? scale.milestoneX(s.earlyStart) : scale.startX(s.earlyStart)
        var x1 = s.isMilestone ? x0 : scale.finishX(s.earlyFinish)
        if let drag, drag.taskID == id {
            switch drag.kind {
            case .move: x0 += drag.dx; x1 += drag.dx
            case .resize: x1 = max(x0 + scale.pixelsPerDay / 2, x1 + drag.dx)
            }
        }
        return (x0, x1)
    }

    func draw(in context: inout GraphicsContext, rect: CGRect) {
        scale.drawCalendarBackground(in: &context, rect: rect)

        let firstRow = max(Int(rect.minY / rowHeight), 0)
        let lastRow = min(Int(rect.maxY / rowHeight) + 1, rows.count - 1)
        guard firstRow <= lastRow else { return }

        // Selection highlight and row lines.
        var lines = Path()
        for row in firstRow...lastRow {
            let y = CGFloat(row + 1) * rowHeight
            lines.move(to: CGPoint(x: rect.minX, y: y - 0.5))
            lines.addLine(to: CGPoint(x: rect.maxX, y: y - 0.5))
            if controller.selection.contains(rows[row]) {
                context.fill(Path(CGRect(x: rect.minX, y: CGFloat(row) * rowHeight, width: rect.width, height: rowHeight)),
                             with: .color(.accentColor.opacity(0.12)))
            }
        }
        context.stroke(lines, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

        drawLinks(in: &context, rect: rect)

        for row in firstRow...lastRow {
            let id = rows[row]
            guard let s = schedule[id] else { continue }
            if hasBaseline, let task = controller.project.task(id), let bStart = task.baselineStart, let bFinish = task.baselineFinish {
                let x0 = scale.x(for: bStart)
                let x1 = scale.x(for: bFinish) + (s.isMilestone ? 0 : scale.pixelsPerDay)
                let y = barY(row: row) + barHeight + 2
                context.fill(Path(roundedRect: CGRect(x: x0, y: y, width: max(x1 - x0, 3), height: 4), cornerRadius: 1),
                             with: .color(.gray.opacity(0.55)))
            }
            if let task = controller.project.task(id) {
                drawDateLimits(task, s, row: row, in: &context)
            }
            if s.isSummary {
                drawSummary(id, s, row: row, in: &context)
            } else if s.isMilestone {
                drawMilestone(id, s, row: row, in: &context)
            } else {
                drawTask(id, s, row: row, in: &context)
            }
        }
    }

    private func drawTask(_ id: UUID, _ s: ScheduledTask, row: Int, in context: inout GraphicsContext) {
        let (x0, x1) = barSpan(id, s)
        let y = barY(row: row)
        let bar = CGRect(x: x0, y: y, width: max(x1 - x0, 2), height: barHeight)
        let color = color(for: s)
        context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(color.opacity(0.85)))
        if s.percentComplete > 0 {
            let done = CGRect(x: x0, y: y + barHeight * 0.3, width: bar.width * s.percentComplete / 100, height: barHeight * 0.4)
            context.fill(Path(roundedRect: done, cornerRadius: 1.5), with: .color(.black.opacity(0.55)))
        }
        if controller.schedule.cycleTaskIDs.contains(id) {
            context.stroke(Path(roundedRect: bar.insetBy(dx: -1, dy: -1), cornerRadius: 3), with: .color(.orange), lineWidth: 1.5)
        }
        if controller.selection.contains(id) {
            context.stroke(Path(roundedRect: bar.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(.primary.opacity(0.6)), lineWidth: 1)
        }
        let names = controller.project.assignments.filter { $0.taskID == id }.compactMap { a -> String? in
            guard let r = controller.project.resource(a.resourceID) else { return nil }
            return abs(a.units - 1) < 1e-9 ? r.name : "\(r.name) [\(Notation.formatPercent(a.units))]"
        }
        if !names.isEmpty {
            drawLabel(Text(names.joined(separator: ", ")), at: CGPoint(x: bar.maxX + 6, y: bar.midY), in: &context)
        }
    }

    private func drawMilestone(_ id: UUID, _ s: ScheduledTask, row: Int, in context: inout GraphicsContext) {
        let (x, _) = barSpan(id, s)
        let size = barHeight + 3
        let cy = barY(row: row) + barHeight / 2
        var diamond = Path()
        diamond.move(to: CGPoint(x: x, y: cy - size / 2))
        diamond.addLine(to: CGPoint(x: x + size / 2, y: cy))
        diamond.addLine(to: CGPoint(x: x, y: cy + size / 2))
        diamond.addLine(to: CGPoint(x: x - size / 2, y: cy))
        diamond.closeSubpath()
        context.fill(diamond, with: .color(controller.showCriticalPath && s.isCritical ? Self.criticalColor : .primary))
        drawLabel(Text(s.finish, format: .dateTime.day().month(.abbreviated)), at: CGPoint(x: x + size / 2 + 5, y: cy), in: &context)
    }

    /// "Starts after" is a bracket opening at the earliest start; "Finish by" is a downward arrow
    /// at the end of the deadline day, green when met and red when missed (MS Project's deadline marker).
    private func drawDateLimits(_ task: ProjectTask, _ s: ScheduledTask, row: Int, in context: inout GraphicsContext) {
        let top = CGFloat(row) * rowHeight + 2
        let bottom = CGFloat(row + 1) * rowHeight - 2
        if let date = task.earliestStart {
            let x = scale.x(for: date)
            var bracket = Path()
            bracket.move(to: CGPoint(x: x + 4, y: top + 1))
            bracket.addLine(to: CGPoint(x: x, y: top + 1))
            bracket.addLine(to: CGPoint(x: x, y: bottom - 1))
            bracket.addLine(to: CGPoint(x: x + 4, y: bottom - 1))
            context.stroke(bracket, with: .color(.secondary), lineWidth: 1.5)
        }
        if let date = task.finishBy {
            let day = schedule.calendar.dayIndex(onOrBefore: date)
            let x = scale.finishX(Double(day + 1))
            let color: Color = s.missesDeadline ? Self.criticalColor : .green
            var arrow = Path()
            arrow.move(to: CGPoint(x: x, y: top))
            arrow.addLine(to: CGPoint(x: x, y: bottom - 6))
            context.stroke(arrow, with: .color(color), lineWidth: 1.5)
            context.fill(arrowHead(at: CGPoint(x: x, y: bottom), pointing: .down), with: .color(color))
        }
    }

    /// A small label beside a bar, on a backing so link lines don't run through the text.
    private func drawLabel(_ text: Text, at point: CGPoint, in context: inout GraphicsContext) {
        let resolved = context.resolve(text.font(.system(size: 10)).foregroundStyle(.secondary))
        let size = resolved.measure(in: CGSize(width: 600, height: 40))
        let backing = CGRect(x: point.x - 2, y: point.y - size.height / 2 - 1, width: size.width + 4, height: size.height + 2)
        context.fill(Path(roundedRect: backing, cornerRadius: 2), with: .color(.chartBackground.opacity(0.85)))
        context.draw(resolved, at: point, anchor: .leading)
    }

    private func drawSummary(_ id: UUID, _ s: ScheduledTask, row: Int, in context: inout GraphicsContext) {
        let x0 = scale.startX(s.earlyStart)
        let x1 = max(scale.finishX(s.earlyFinish), x0 + 2)
        let y = barY(row: row) + barHeight * 0.15
        let h = barHeight * 0.45
        let color: Color = .primary.opacity(0.75)
        var shape = Path()
        shape.addRect(CGRect(x: x0, y: y, width: x1 - x0, height: h))
        // End caps pointing down, like MS Project.
        for (edge, dir) in [(x0, 1.0), (x1, -1.0)] {
            shape.move(to: CGPoint(x: edge, y: y))
            shape.addLine(to: CGPoint(x: edge + 6 * dir, y: y + h))
            shape.addLine(to: CGPoint(x: edge, y: y + h + 6))
            shape.closeSubpath()
        }
        context.fill(shape, with: .color(color))
        if s.percentComplete > 0 {
            context.fill(Path(CGRect(x: x0, y: y + h * 0.35, width: (x1 - x0) * s.percentComplete / 100, height: h * 0.3)),
                         with: .color(.black.opacity(0.4)))
        }
    }

    private func drawLinks(in context: inout GraphicsContext, rect: CGRect) {
        let rowOf = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1, $0) })
        var normal = Path(), critical = Path()
        var normalHeads = Path(), criticalHeads = Path()
        for d in controller.project.dependencies {
            guard let pr = rowOf[d.predecessorID], let sr = rowOf[d.successorID],
                  let ps = schedule[d.predecessorID], let ss = schedule[d.successorID] else { continue }
            let (p0, p1) = barSpan(d.predecessorID, ps)
            let (s0, s1) = barSpan(d.successorID, ss)
            let py = barY(row: pr) + barHeight / 2
            let sy = barY(row: sr) + barHeight / 2
            let fromEnd = d.type == .finishToStart || d.type == .finishToFinish
            let toStart = d.type == .finishToStart || d.type == .startToStart
            let px = fromEnd ? p1 : p0
            let sx = toStart ? s0 : s1
            let minY = min(py, sy) - rowHeight, maxY = max(py, sy) + rowHeight
            guard maxY >= rect.minY, minY <= rect.maxY else { continue }

            let isCritical = controller.showCriticalPath && ps.isCritical && ss.isCritical
            var path = Path(), head = Path()
            let down = sy > py
            let barEdgeY = down ? sy - barHeight / 2 - 1 : sy + barHeight / 2 + 1
            if toStart, sx - px >= 4 {
                // Elbow: across, then down onto the successor's start.
                let ax = max(sx + 3, px + 4)
                path.move(to: CGPoint(x: px, y: py))
                path.addLine(to: CGPoint(x: ax, y: py))
                path.addLine(to: CGPoint(x: ax, y: barEdgeY))
                head = arrowHead(at: CGPoint(x: ax, y: barEdgeY), pointing: down ? .down : .up)
            } else if toStart {
                // Successor starts before the predecessor ends: route around.
                let midY = down ? CGFloat(sr) * rowHeight : CGFloat(sr + 1) * rowHeight
                let outX = fromEnd ? px + 6 : px - 6
                path.move(to: CGPoint(x: px, y: py))
                path.addLine(to: CGPoint(x: outX, y: py))
                path.addLine(to: CGPoint(x: outX, y: midY))
                path.addLine(to: CGPoint(x: sx - 8, y: midY))
                path.addLine(to: CGPoint(x: sx - 8, y: sy))
                path.addLine(to: CGPoint(x: sx - 1, y: sy))
                head = arrowHead(at: CGPoint(x: sx - 1, y: sy), pointing: .right)
            } else {
                // Into the successor's finish from the right.
                let outX = max(px, sx) + 10
                path.move(to: CGPoint(x: px, y: py))
                path.addLine(to: CGPoint(x: outX, y: py))
                path.addLine(to: CGPoint(x: outX, y: sy))
                path.addLine(to: CGPoint(x: sx + 1, y: sy))
                head = arrowHead(at: CGPoint(x: sx + 1, y: sy), pointing: .left)
            }
            if isCritical {
                critical.addPath(path); criticalHeads.addPath(head)
            } else {
                normal.addPath(path); normalHeads.addPath(head)
            }
        }
        let gray = Color.secondary.opacity(0.8)
        context.stroke(normal, with: .color(gray), lineWidth: 1)
        context.fill(normalHeads, with: .color(gray))
        context.stroke(critical, with: .color(Self.criticalColor), lineWidth: 1.2)
        context.fill(criticalHeads, with: .color(Self.criticalColor))
    }

    private enum Direction { case up, down, left, right }

    private func arrowHead(at tip: CGPoint, pointing direction: Direction) -> Path {
        let l: CGFloat = 5, w: CGFloat = 3.5
        var p = Path()
        p.move(to: tip)
        switch direction {
        case .down:
            p.addLine(to: CGPoint(x: tip.x - w, y: tip.y - l)); p.addLine(to: CGPoint(x: tip.x + w, y: tip.y - l))
        case .up:
            p.addLine(to: CGPoint(x: tip.x - w, y: tip.y + l)); p.addLine(to: CGPoint(x: tip.x + w, y: tip.y + l))
        case .right:
            p.addLine(to: CGPoint(x: tip.x - l, y: tip.y - w)); p.addLine(to: CGPoint(x: tip.x - l, y: tip.y + w))
        case .left:
            p.addLine(to: CGPoint(x: tip.x + l, y: tip.y - w)); p.addLine(to: CGPoint(x: tip.x + l, y: tip.y + w))
        }
        p.closeSubpath()
        return p
    }

    /// Which bar (and which part of it) is under `point`, for dragging.
    func hitTest(_ point: CGPoint) -> GanttDrag? {
        let row = Int(point.y / rowHeight)
        guard rows.indices.contains(row), let s = schedule[rows[row]], !s.isSummary else { return nil }
        let id = rows[row]
        let (x0, x1) = barSpan(id, s)
        if s.isMilestone {
            return abs(point.x - x0) <= barHeight ? GanttDrag(taskID: id, kind: .move) : nil
        }
        if point.x >= x1 - 6, point.x <= x1 + 5 { return GanttDrag(taskID: id, kind: .resize) }
        if point.x >= x0 - 2, point.x < x1 - 6 { return GanttDrag(taskID: id, kind: .move) }
        return nil
    }
}
