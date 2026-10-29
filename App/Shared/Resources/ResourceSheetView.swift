import SwiftUI
import ProjectorKit

/// The resource sheet: who's on the project, their capacity, rate, and total work and cost.
struct ResourceSheetView: View {
    @Bindable var controller: ProjectController
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let project = controller.project
        let loads = controller.schedule.resourceLoads
        if project.resources.isEmpty {
            ContentUnavailableView {
                Label("No Resources", systemImage: "person.2")
            } description: {
                Text("Resources are the people (or equipment) that do the work. You can also create them by typing names into a task's Resources cell.")
            } actions: {
                Button("Add Resource") { controller.addResource() }.buttonStyle(.borderedProminent)
            }
        } else if sizeClass == .compact {
            List(selection: $controller.resourceSelection) {
                ForEach(project.resources) { r in
                    let load = loads[r.id] ?? ResourceLoad()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Circle().fill(ResourcePalette.color(for: r.id, in: project)).frame(width: 8, height: 8)
                            Text(r.name).font(.headline)
                            if load.isOverallocated { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                        }
                        Text("\(Notation.formatPercent(r.maxUnits)) · \(Notation.formatNumber(load.work))h · \(load.cost.formatted(.currency(code: project.currencyCode)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(r.id)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.resourceSelection = [r.id]; controller.showInspector = true }
                }
                .onDelete { offsets in
                    controller.resourceSelection = Set(offsets.map { project.resources[$0].id })
                    controller.deleteResources()
                }
            }
        } else {
            Table(project.resources, selection: $controller.resourceSelection) {
                TableColumn("") { r in
                    if loads[r.id]?.isOverallocated == true {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            .help("Overallocated — try Level Resources")
                    }
                }
                .width(20)
                TableColumn("Resource Name") { r in
                    HStack {
                        Circle().fill(ResourcePalette.color(for: r.id, in: project)).frame(width: 8, height: 8)
                        CommitTextField(value: r.name, placeholder: "Name") { name in
                            controller.updateResource(r.id, "Rename Resource") { $0.name = name }
                        }
                    }
                }
                .width(min: 140, ideal: 200)
                TableColumn("Initials") { r in
                    CommitTextField(value: r.initials, placeholder: "") { v in
                        controller.updateResource(r.id, "Change Initials") { $0.initials = v }
                    }
                }
                .width(60)
                TableColumn("Group") { r in
                    CommitTextField(value: r.group, placeholder: "") { v in
                        controller.updateResource(r.id, "Change Group") { $0.group = v }
                    }
                }
                .width(min: 80, ideal: 110)
                TableColumn("Max Units") { r in
                    CommitTextField(value: Notation.formatPercent(r.maxUnits), placeholder: "") { v in
                        guard let pct = Double(v.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)), pct > 0 else { return }
                        controller.updateResource(r.id, "Change Max Units") { $0.maxUnits = pct / 100 }
                    }
                }
                .width(80)
                TableColumn("Std. Rate") { r in
                    CommitTextField(value: r.standardRate.formatted(.currency(code: project.currencyCode)) + "/h", placeholder: "") { v in
                        let digits = v.filter { $0.isNumber || $0 == "." }
                        guard let rate = Double(digits) else { return }
                        controller.updateResource(r.id, "Change Rate") { $0.standardRate = rate }
                    }
                }
                .width(90)
                TableColumn("Work") { r in
                    Text("\(Notation.formatNumber(loads[r.id]?.work ?? 0)) h").foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Cost") { r in
                    Text((loads[r.id]?.cost ?? 0).formatted(.currency(code: project.currencyCode))).foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("Peak") { r in
                    let load = loads[r.id] ?? ResourceLoad()
                    Text(Notation.formatPercent(load.peak)).foregroundStyle(load.isOverallocated ? .red : .secondary)
                }
                .width(60)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Delete", role: .destructive) {
                    controller.resourceSelection = ids
                    controller.deleteResources()
                }
            } primaryAction: { _ in
                controller.showInspector = true
            }
        }
    }
}
