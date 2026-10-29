import SwiftUI
import ProjectorKit

/// Task Information: everything about the selected task, including links and assignments.
struct TaskInspector: View {
    @Bindable var controller: ProjectController

    var body: some View {
        Group {
            if controller.selection.count > 1 {
                MultiTaskInspector(controller: controller)
            } else if let id = controller.primarySelection, let task = controller.project.task(id), let s = controller.schedule[id] {
                SingleTaskInspector(controller: controller, task: task, s: s)
                    .id(id)
            } else {
                ContentUnavailableView("No Task Selected", systemImage: "square.dashed",
                                       description: Text("Select a task to see its details."))
            }
        }
    }
}

private struct MultiTaskInspector: View {
    let controller: ProjectController

    var body: some View {
        Form {
            Section {
                Text("\(controller.selection.count) tasks selected").font(.headline)
            }
            Section {
                Button("Link Tasks (Finish-to-Start)", systemImage: "link") { controller.linkSelection() }
                Button("Unlink Tasks", systemImage: "scissors") { controller.unlinkSelection() }
                Button("Indent", systemImage: "increase.indent") { controller.indent() }
                Button("Outdent", systemImage: "decrease.indent") { controller.outdent() }
            }
            Section("Progress") {
                HStack {
                    ForEach([0, 25, 50, 75, 100], id: \.self) { pct in
                        Button("\(pct)%") {
                            let ids = controller.selection
                            controller.edit("Set % Complete") { p in
                                for i in p.tasks.indices where ids.contains(p.tasks[i].id) {
                                    p.tasks[i].percentComplete = Double(pct)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Section {
                Button("Delete Tasks", systemImage: "trash", role: .destructive) { controller.deleteSelection() }
            }
        }
        .formStyle(.grouped)
    }
}

/// "Starts after" and "Finish by" dates. On a summary they apply to every subtask.
private struct DateLimitsSection: View {
    let controller: ProjectController
    let task: ProjectTask
    let s: ScheduledTask

    var body: some View {
        Section {
            Toggle("Starts after", isOn: Binding(
                get: { task.startAfter != nil },
                set: { on in
                    let date = Calendar.current.startOfDay(for: s.start)
                    controller.updateTask(task.id, on ? "Set Start Date Limit" : "Clear Start Date Limit") { $0.startAfter = on ? date : nil }
                }))
            if let date = task.startAfter {
                DatePicker("Earliest start", selection: Binding(
                    get: { date },
                    set: { d in controller.updateTask(task.id, "Change Start Date Limit") { $0.startAfter = Calendar.current.startOfDay(for: d) } }),
                           displayedComponents: .date)
            }
            Toggle("Finish by", isOn: Binding(
                get: { task.finishBy != nil },
                set: { on in
                    let date = Calendar.current.startOfDay(for: s.finish)
                    controller.updateTask(task.id, on ? "Set Deadline" : "Clear Deadline") { $0.finishBy = on ? date : nil }
                }))
            if let date = task.finishBy {
                DatePicker("Deadline", selection: Binding(
                    get: { date },
                    set: { d in controller.updateTask(task.id, "Change Deadline") { $0.finishBy = Calendar.current.startOfDay(for: d) } }),
                           displayedComponents: .date)
            }
            if s.missesDeadline {
                Label(s.totalSlack < 0
                      ? "Late by \(Notation.formatDuration(-s.totalSlack)) against a deadline."
                      : "A subtask misses its deadline.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(GanttRenderer.criticalColor)
            }
        } header: {
            Text("Date limits")
        } footer: {
            Text(s.isSummary
                 ? "These apply to every subtask. A deadline doesn't move work; it makes late tasks critical and flags them."
                 : "A deadline doesn't move the task; it makes it critical and flags it if it finishes late.")
        }
    }
}

private struct SingleTaskInspector: View {
    let controller: ProjectController
    let task: ProjectTask
    let s: ScheduledTask

    private var project: Project { controller.project }
    private var outline: Outline { controller.schedule.outline }
    private var currency: String { project.currencyCode }

    var body: some View {
        Form {
            Section {
                CommitTextField(value: task.name, placeholder: "Task name") { name in
                    controller.updateTask(task.id, "Rename Task") { $0.name = name }
                }
                .font(.headline)
                LabeledContent("ID / WBS", value: "\((outline.rowIndex[task.id] ?? 0) + 1)  ·  \(outline.wbs[task.id] ?? "")")
                if s.isSummary {
                    LabeledContent("Duration", value: Notation.formatDuration(s.duration))
                } else {
                    LabeledContent("Duration") {
                        CommitTextField(value: Notation.formatDuration(task.duration), placeholder: "5d") {
                            controller.setDuration(task.id, text: $0)
                        }
                        .multilineTextAlignment(.trailing)
                    }
                }
            }

            Section("Schedule") {
                LabeledContent("Start", value: s.start.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Finish", value: s.finish.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Total slack") {
                    Text(Notation.formatDuration(s.totalSlack))
                        .foregroundStyle(s.totalSlack < -1e-6 ? GanttRenderer.criticalColor : .primary)
                }
                LabeledContent("Critical") {
                    Text(s.isCritical ? "Yes" : "No").foregroundStyle(s.isCritical ? GanttRenderer.criticalColor : .secondary)
                }
                if task.levelingDelay > 0 {
                    LabeledContent("Leveling delay", value: Notation.formatDuration(task.levelingDelay))
                }
                if let bs = task.baselineStart, let bf = task.baselineFinish {
                    LabeledContent("Baseline", value: "\(bs.formatted(date: .abbreviated, time: .omitted)) – \(bf.formatted(date: .abbreviated, time: .omitted))")
                }
                if !s.isSummary {
                    Picker("Constraint", selection: Binding(
                        get: { task.constraint },
                        set: { value in
                            let fallback = s.start
                            controller.updateTask(task.id, "Change Constraint") {
                                $0.constraint = value
                                if value != .asSoonAsPossible, $0.constraintDate == nil { $0.constraintDate = fallback }
                            }
                        })) {
                        ForEach(ConstraintType.selectable, id: \.self) { Text($0.title).tag($0) }
                    }
                    if task.constraint == .mustStartOn {
                        DatePicker("Constraint date", selection: Binding(
                            get: { task.constraintDate ?? s.start },
                            set: { date in controller.updateTask(task.id, "Change Constraint Date") { $0.constraintDate = date } }),
                                   displayedComponents: .date)
                    }
                }
            }

            DateLimitsSection(controller: controller, task: task, s: s)

            Section("Progress") {
                if s.isSummary {
                    ProgressView(value: s.percentComplete, total: 100) {
                        Text("\(Int(s.percentComplete))% complete")
                    }
                } else {
                    HStack {
                        Slider(value: Binding(
                            get: { task.percentComplete },
                            set: { v in controller.updateTask(task.id, "Change % Complete") { $0.percentComplete = v.rounded() } }),
                               in: 0...100, step: 5)
                        Text("\(Int(task.percentComplete))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }

            PredecessorsSection(controller: controller, task: task)
            SuccessorsSection(controller: controller, task: task)
            if !s.isSummary {
                AssignmentsSection(controller: controller, task: task)
            }

            Section("Cost") {
                LabeledContent("Work", value: "\(Notation.formatNumber(s.work)) h")
                LabeledContent("Cost", value: s.cost.formatted(.currency(code: currency)))
            }

            Section("Notes") {
                CommitTextField(value: task.notes, placeholder: "Notes", axis: .vertical) { notes in
                    controller.updateTask(task.id, "Edit Notes") { $0.notes = notes }
                }
                .lineLimit(3...10)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PredecessorsSection: View {
    let controller: ProjectController
    let task: ProjectTask

    var body: some View {
        let project = controller.project
        let outline = controller.schedule.outline
        let deps = project.dependencies.filter { $0.successorID == task.id }
        Section("Predecessors") {
            ForEach(deps) { d in
                if let pred = project.task(d.predecessorID) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\((outline.rowIndex[pred.id] ?? 0) + 1)").monospacedDigit().foregroundStyle(.secondary)
                            Text(pred.name).lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                controller.edit("Remove Link") { $0.dependencies.removeAll { $0.id == d.id } }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        HStack {
                            Picker("Type", selection: Binding(
                                get: { d.type },
                                set: { t in controller.edit("Change Link Type") { p in
                                    if let i = p.dependencies.firstIndex(where: { $0.id == d.id }) { p.dependencies[i].type = t }
                                } })) {
                                ForEach(DependencyType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            Text("Lag")
                            CommitTextField(value: Notation.formatNumber(d.lag) + "d", placeholder: "0d") { text in
                                let negative = text.trimmingCharacters(in: .whitespaces).hasPrefix("-")
                                let body = text.trimmingCharacters(in: CharacterSet(charactersIn: " +-"))
                                guard let value = Notation.parseDuration(body, settings: project.calendar) else { return }
                                controller.edit("Change Lag") { p in
                                    if let i = p.dependencies.firstIndex(where: { $0.id == d.id }) {
                                        p.dependencies[i].lag = negative ? -value : value
                                    }
                                }
                            }
                            .frame(width: 60)
                        }
                    }
                }
            }
            Menu {
                ForEach(candidates(project: project, outline: outline)) { t in
                    Button("\((outline.rowIndex[t.id] ?? 0) + 1)  \(t.name)") {
                        controller.edit("Add Link") {
                            try $0.addDependency(Dependency(predecessorID: t.id, successorID: task.id))
                        }
                    }
                }
            } label: {
                Label("Add Predecessor", systemImage: "plus")
            }
        }
    }

    private func candidates(project: Project, outline: Outline) -> [ProjectTask] {
        let existing = Set(project.dependencies.filter { $0.successorID == task.id }.map(\.predecessorID))
        return project.tasks.filter { t in
            t.id != task.id && !existing.contains(t.id)
                && !outline.isAncestor(t.id, of: task.id) && !outline.isAncestor(task.id, of: t.id)
        }
    }
}

private struct SuccessorsSection: View {
    let controller: ProjectController
    let task: ProjectTask

    var body: some View {
        let project = controller.project
        let outline = controller.schedule.outline
        let deps = project.dependencies.filter { $0.predecessorID == task.id }
        if !deps.isEmpty {
            Section("Successors") {
                ForEach(deps) { d in
                    if let succ = project.task(d.successorID) {
                        Button {
                            controller.select(succ.id)
                        } label: {
                            HStack {
                                Text("\((outline.rowIndex[succ.id] ?? 0) + 1)").monospacedDigit().foregroundStyle(.secondary)
                                Text(succ.name).lineLimit(1)
                                Spacer()
                                Text(Notation.formatPredecessor(row: (outline.rowIndex[task.id] ?? 0) + 1, type: d.type, lag: d.lag)
                                    .drop { $0.isNumber })
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct AssignmentsSection: View {
    let controller: ProjectController
    let task: ProjectTask

    var body: some View {
        let project = controller.project
        let assignments = project.assignments.filter { $0.taskID == task.id }
        Section("Resources") {
            ForEach(assignments) { a in
                if let r = project.resource(a.resourceID) {
                    HStack {
                        Circle().fill(ResourcePalette.color(for: r.id, in: project)).frame(width: 8, height: 8)
                        Text(r.name)
                        Spacer()
                        Stepper(Notation.formatPercent(a.units), value: Binding(
                            get: { a.units },
                            set: { v in controller.edit("Change Units") { p in
                                if let i = p.assignments.firstIndex(where: { $0.id == a.id }) { p.assignments[i].units = max(v, 0.05) }
                            } }), in: 0.05...10, step: 0.25)
                            .monospacedDigit()
                            .fixedSize()
                        Button(role: .destructive) {
                            controller.edit("Remove Assignment") { $0.assignments.removeAll { $0.id == a.id } }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            let assigned = Set(assignments.map(\.resourceID))
            Menu {
                ForEach(project.resources.filter { !assigned.contains($0.id) }) { r in
                    Button(r.name) {
                        controller.edit("Assign Resource") {
                            $0.assignments.append(Assignment(taskID: task.id, resourceID: r.id))
                        }
                    }
                }
                Divider()
                Button("New Resource…") {
                    let resource = Resource(name: "New resource")
                    controller.edit("Assign Resource") {
                        $0.resources.append(resource)
                        $0.assignments.append(Assignment(taskID: task.id, resourceID: resource.id))
                    }
                    controller.resourceSelection = [resource.id]
                    controller.mode = .resourceSheet
                }
            } label: {
                Label("Assign Resource", systemImage: "person.badge.plus")
            }
        }
    }
}
