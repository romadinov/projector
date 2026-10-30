import SwiftUI
import ProjectorKit

enum ViewMode: String, CaseIterable, Identifiable {
    case gantt, resourcePlan, resourceSheet

    var id: String { rawValue }
    var title: String {
        switch self {
        case .gantt: "Gantt"
        case .resourcePlan: "Resource Plan"
        case .resourceSheet: "Resources"
        }
    }
    var symbol: String {
        switch self {
        case .gantt: "chart.bar.doc.horizontal"
        case .resourcePlan: "person.2.wave.2"
        case .resourceSheet: "person.crop.rectangle.stack"
        }
    }
}

/// Per-window editing state plus every undoable command on the document.
@MainActor @Observable
final class ProjectController {
    let document: ProjectDocument
    var undoManager: UndoManager?

    var mode: ViewMode = .gantt
    var selection: Set<UUID> = []
    var selectionAnchor: UUID?
    var resourceSelection: Set<UUID> = []
    var collapsed: Set<UUID> = []
    var collapsedResources: Set<UUID> = []
    var pixelsPerDay: CGFloat = 24
    var usageTimescale: Timescale = .week
    var usageValue: UsageValue = .hours
    var showCriticalPath = true
    var showBaseline = true
    var showInspector = false
    var showSettings = false
    var showQuickPlan = false
    var showImporter = false
    /// The format being exported; the save panel is open while it is set.
    var exportFormat: InterchangeFormat?
    var alertMessage: String?

    init(document: ProjectDocument) {
        self.document = document
    }

    var project: Project { document.project }
    var schedule: Schedule { document.schedule }

    // MARK: Undo

    /// Applies a change as one undoable step. Every edit funnels through here so autosave sees it.
    func edit(_ actionName: String, _ change: (inout Project) throws -> Void) {
        var updated = document.project
        do {
            try change(&updated)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        guard updated != document.project else { return }
        replace(with: updated, actionName: actionName)
    }

    private func replace(with project: Project, actionName: String) {
        let previous = document.project
        document.project = project
        undoManager?.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.replace(with: previous, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: Selection

    var primarySelection: UUID? {
        if let anchor = selectionAnchor, selection.contains(anchor) { return anchor }
        return project.tasks.first { selection.contains($0.id) }?.id
    }

    func select(_ id: UUID, extend: Bool = false, toggle: Bool = false) {
        if toggle {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else if extend, let anchor = selectionAnchor,
                  let a = schedule.outline.rowIndex[anchor], let b = schedule.outline.rowIndex[id] {
            let visible = Set(visibleTaskIDs)
            selection = Set(project.tasks[min(a, b)...max(a, b)].map(\.id).filter(visible.contains))
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    var visibleTaskIDs: [UUID] {
        schedule.outline.visibleRows(collapsed: collapsed)
    }

    func toggleCollapsed(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    // MARK: Task commands

    func addTask(milestone: Bool = false) {
        var newID: UUID?
        let after = primarySelection.flatMap { id in collapsed.contains(id) ? lastDescendant(of: id) : id }
        edit(milestone ? "Insert Milestone" : "Insert Task") { p in
            newID = p.insertTask(named: milestone ? "New milestone" : "New task",
                                 duration: milestone ? 0 : 1, after: after)
        }
        if let newID { select(newID) }
    }

    private func lastDescendant(of id: UUID) -> UUID {
        schedule.outline.descendants(of: id).last ?? id
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        edit(ids.count == 1 ? "Delete Task" : "Delete Tasks") { $0.deleteTasks(ids) }
        selection = []
    }

    func indent() { let ids = selection; edit("Indent") { $0.indent(ids) } }
    func outdent() { let ids = selection; edit("Outdent") { $0.outdent(ids) } }
    func moveUp() { guard let id = primarySelection else { return }; edit("Move Up") { $0.moveUp(id) } }
    func moveDown() { guard let id = primarySelection else { return }; edit("Move Down") { $0.moveDown(id) } }
    func linkSelection() { let ids = selection; edit("Link Tasks") { try $0.linkTasks(ids) } }
    func unlinkSelection() { let ids = selection; edit("Unlink Tasks") { $0.unlinkTasks(ids) } }

    func updateTask(_ id: UUID, _ actionName: String, _ change: @escaping (inout ProjectTask) -> Void) {
        edit(actionName) { p in
            guard let i = p.index(of: id) else { return }
            change(&p.tasks[i])
        }
    }

    func setDuration(_ id: UUID, text: String) {
        guard let days = Notation.parseDuration(text, settings: project.calendar) else {
            alertMessage = "“\(text)” isn't a valid duration. Try 5d, 2w or 4h."
            return
        }
        updateTask(id, "Change Duration") { $0.duration = days }
    }

    func setPredecessors(_ id: UUID, text: String) {
        edit("Change Predecessors") { try $0.setPredecessors(of: id, text: text) }
    }

    func setResources(_ id: UUID, text: String) {
        edit("Assign Resources") { try $0.setResources(of: id, text: text) }
    }

    /// Dragging a bar sets its "starts after" date, like MS Project's Start-No-Earlier-Than.
    func moveTask(_ id: UUID, toStart date: Date) {
        let day = schedule.calendar.dayIndex(onOrAfter: date)
        let start = schedule.calendar.date(forDay: day)
        updateTask(id, "Move Task") { task in
            if task.constraint == .startNoEarlierThan { task.constraint = .asSoonAsPossible }
            if task.constraint != .mustStartOn { task.startAfter = start } else { task.constraintDate = start }
            task.levelingDelay = 0
        }
    }

    func resizeTask(_ id: UUID, toFinish date: Date) {
        guard let s = schedule[id] else { return }
        let first = Int(s.earlyStart.rounded(.down))
        let last = schedule.calendar.dayIndex(onOrBefore: date)
        let duration = Double(max(last - first + 1, 1)) - (s.earlyStart - Double(first))
        updateTask(id, "Change Duration") { $0.duration = max(duration, 0.5) }
    }

    // MARK: Resources

    func addResource() {
        let resource = Resource(name: "New resource")
        edit("Add Resource") { $0.resources.append(resource) }
        resourceSelection = [resource.id]
    }

    func deleteResources() {
        let ids = resourceSelection
        guard !ids.isEmpty else { return }
        edit("Delete Resource") { $0.deleteResources(ids) }
        resourceSelection = []
    }

    func updateResource(_ id: UUID, _ actionName: String, _ change: @escaping (inout Resource) -> Void) {
        edit(actionName) { p in
            guard let i = p.resources.firstIndex(where: { $0.id == id }) else { return }
            change(&p.resources[i])
        }
    }

    // MARK: Tools

    func levelResources() {
        let result = Leveler.level(project)
        edit("Level Resources") { $0 = result.project }
        if !result.unresolvedResourceIDs.isEmpty {
            let names = result.unresolvedResourceIDs.compactMap { project.resource($0)?.name }.sorted()
            alertMessage = "Some assignments exceed a resource's maximum units on their own and can't be fixed by delaying: \(names.joined(separator: ", ")). Lower the assignment units or raise the resource's max units."
        }
    }

    func clearLeveling() { edit("Clear Leveling") { Leveler.clear(&$0) } }
    func setBaseline() { let s = schedule; edit("Set Baseline") { $0.setBaseline(using: s) } }
    func clearBaseline() { edit("Clear Baseline") { $0.clearBaseline() } }

    func loadSample() {
        edit("Load Sample Project") { $0 = Project.sample() }
        collapsed = []
        selection = []
    }

    /// Replaces the plan with an MS Project XML or Primavera XER file (one undoable step).
    func importPlan(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try Interchange.importFile(Data(contentsOf: url))
            edit("Import \(url.lastPathComponent)") { $0 = result.project }
            collapsed = []
            selection = []
            mode = .gantt
            let summary = "Imported \(result.project.tasks.count) tasks, \(result.project.dependencies.count) links and \(result.project.resources.count) resources. Undo restores your previous plan."
            alertMessage = ([summary] + result.warnings).joined(separator: "\n\n")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Zoom changes the bar scale in the Gantt chart and the column period in the resource plan.
    func zoomIn() {
        if mode == .resourcePlan {
            usageTimescale = usageTimescale == .month ? .week : .day
        } else {
            pixelsPerDay = min(pixelsPerDay * 1.5, 80)
        }
    }

    func zoomOut() {
        if mode == .resourcePlan {
            usageTimescale = usageTimescale == .day ? .week : .month
        } else {
            pixelsPerDay = max(pixelsPerDay / 1.5, 2)
        }
    }

    /// Copies the resource plan as tab-separated values for pasting into a spreadsheet.
    func copyResourcePlan() {
        let text = UsageGrid(controller: self).tabSeparated()
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
