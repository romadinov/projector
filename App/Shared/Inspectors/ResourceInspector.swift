import SwiftUI
import ProjectorKit

struct ResourceInspector: View {
    @Bindable var controller: ProjectController

    var body: some View {
        Group {
            if let id = controller.resourceSelection.first, let r = controller.project.resource(id) {
                ResourceDetail(controller: controller, resource: r).id(id)
            } else {
                ContentUnavailableView("No Resource Selected", systemImage: "person.crop.circle.dashed",
                                       description: Text("Select a resource to see its details."))
            }
        }
    }
}

private struct ResourceDetail: View {
    let controller: ProjectController
    let resource: Resource

    var body: some View {
        let project = controller.project
        let load = controller.schedule.resourceLoads[resource.id] ?? ResourceLoad()
        let id = resource.id
        Form {
            Section {
                CommitTextField(value: resource.name, placeholder: "Name") { v in
                    controller.updateResource(id, "Rename Resource") { $0.name = v }
                }
                .font(.headline)
                LabeledContent("Initials") {
                    CommitTextField(value: resource.initials, placeholder: "") { v in
                        controller.updateResource(id, "Change Initials") { $0.initials = v }
                    }.multilineTextAlignment(.trailing)
                }
                LabeledContent("Group") {
                    CommitTextField(value: resource.group, placeholder: "Team") { v in
                        controller.updateResource(id, "Change Group") { $0.group = v }
                    }.multilineTextAlignment(.trailing)
                }
                LabeledContent("Email") {
                    CommitTextField(value: resource.email, placeholder: "name@example.com") { v in
                        controller.updateResource(id, "Change Email") { $0.email = v }
                    }.multilineTextAlignment(.trailing)
                }
            }
            Section("Availability & Cost") {
                Stepper("Max units: \(Notation.formatPercent(resource.maxUnits))", value: Binding(
                    get: { resource.maxUnits },
                    set: { v in controller.updateResource(id, "Change Max Units") { $0.maxUnits = max(v, 0.05) } }),
                        in: 0.05...20, step: 0.25)
                LabeledContent("Standard rate (per hour)") {
                    CommitTextField(value: Notation.formatNumber(resource.standardRate), placeholder: "0") { v in
                        guard let rate = Double(v.filter { $0.isNumber || $0 == "." }) else { return }
                        controller.updateResource(id, "Change Rate") { $0.standardRate = rate }
                    }.multilineTextAlignment(.trailing)
                }
                LabeledContent("Total work", value: "\(Notation.formatNumber(load.work)) h")
                LabeledContent("Total cost", value: load.cost.formatted(.currency(code: project.currencyCode)))
                LabeledContent("Peak load") {
                    Text(Notation.formatPercent(load.peak)).foregroundStyle(load.isOverallocated ? .red : .secondary)
                }
            }
            if load.isOverallocated, let first = load.overallocatedDays.first {
                Section {
                    Label("Overallocated on \(load.overallocatedDays.count) working day(s), starting \(controller.schedule.calendar.date(forDay: first).formatted(date: .abbreviated, time: .omitted)).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Level Resources") { controller.levelResources() }
                }
            }
            Section("Assignments") {
                let assignments = project.assignments.filter { $0.resourceID == id }
                if assignments.isEmpty {
                    Text("Not assigned to any tasks.").foregroundStyle(.secondary)
                }
                ForEach(assignments) { a in
                    if let task = project.task(a.taskID), let s = controller.schedule[a.taskID] {
                        Button {
                            controller.select(task.id)
                            controller.mode = .gantt
                        } label: {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(task.name)
                                    Spacer()
                                    Text(Notation.formatPercent(a.units)).foregroundStyle(.secondary)
                                }
                                Text("\(s.start.formatted(date: .abbreviated, time: .omitted)) – \(s.finish.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                Button("Delete Resource", systemImage: "trash", role: .destructive) {
                    controller.resourceSelection = [id]
                    controller.deleteResources()
                }
            }
        }
        .formStyle(.grouped)
    }
}
