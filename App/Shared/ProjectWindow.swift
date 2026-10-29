import SwiftUI
import ProjectorKit

/// One open project: the Gantt / resource views, toolbar, inspector and sheets.
struct ProjectWindow: View {
    let document: ProjectDocument
    @State private var controller: ProjectController
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(document: ProjectDocument) {
        self.document = document
        _controller = State(initialValue: ProjectController(document: document))
    }

    var body: some View {
        #if os(iOS)
        // DocumentGroupLaunchScene drops toolbar items from document views unless they
        // live in their own NavigationStack (Apple Developer Forums 766652 / 778471).
        NavigationStack { content }
        #else
        content
        #endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            switch controller.mode {
            case .gantt: GanttView(controller: controller)
            case .resourcePlan: ResourcePlanView(controller: controller)
            case .resourceSheet: ResourceSheetView(controller: controller)
            }
            StatusBar(controller: controller)
        }
        .toolbar { ProjectToolbar(controller: controller, compact: sizeClass == .compact) }
        .inspector(isPresented: $controller.showInspector) {
            InspectorContent(controller: controller, compact: sizeClass == .compact)
                .inspectorColumnWidth(min: 280, ideal: 330, max: 460)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $controller.showSettings) { ProjectSettingsView(controller: controller) }
        .sheet(isPresented: $controller.showQuickPlan) { QuickPlanView(controller: controller) }
        .alert("Projector", isPresented: Binding(
            get: { controller.alertMessage != nil },
            set: { if !$0 { controller.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.alertMessage ?? "")
        }
        .focusedSceneValue(controller)
        .onAppear { controller.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in controller.undoManager = manager }
    }
}

/// On iPhone the inspector is a sheet, so it gets a title bar with Done.
private struct InspectorContent: View {
    let controller: ProjectController
    let compact: Bool

    var body: some View {
        if compact {
            VStack(spacing: 0) {
                HStack {
                    Text(controller.mode == .gantt ? "Task" : "Resource").font(.headline)
                    Spacer()
                    Button("Done") { controller.showInspector = false }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 4)
                inspector
            }
        } else {
            inspector
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if controller.mode == .gantt {
            TaskInspector(controller: controller)
        } else {
            ResourceInspector(controller: controller)
        }
    }
}

struct StatusBar: View {
    let controller: ProjectController
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let s = controller.schedule
        let project = controller.project
        let overloaded = s.resourceLoads.values.filter(\.isOverallocated).count
        let critical = project.tasks.filter { s[$0.id].map { !$0.isSummary && $0.isCritical } ?? false }.count
        let compact = sizeClass == .compact
        HStack(spacing: compact ? 10 : 14) {
            if !compact {
                Text(project.name).fontWeight(.medium)
                Text("\(s.projectStart.formatted(date: .abbreviated, time: .omitted)) → \(s.projectFinish.formatted(date: .abbreviated, time: .omitted))")
            } else {
                Text("Finish \(s.projectFinish.formatted(.dateTime.day().month(.abbreviated)))")
            }
            Text(Notation.formatDuration(s.durationDays))
            Text("\(critical) critical").foregroundStyle(critical > 0 ? GanttRenderer.criticalColor : .secondary)
            if overloaded > 0 {
                Button {
                    controller.levelResources()
                } label: {
                    Label(compact ? "\(overloaded)" : "\(overloaded) overallocated", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Level resources")
            }
            if s.missedDeadlineCount > 0 {
                Label(compact ? "\(s.missedDeadlineCount)" : "\(s.missedDeadlineCount) late",
                      systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(GanttRenderer.criticalColor)
                    .help("Tasks that finish after their deadline")
            }
            if !s.cycleTaskIDs.isEmpty {
                Label("Circular links", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            if !compact {
                Text(s.totalCost.formatted(.currency(code: project.currencyCode)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct ProjectToolbar: ToolbarContent {
    @Bindable var controller: ProjectController
    let compact: Bool

    private var isIOS: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private var pickerPlacement: ToolbarItemPlacement {
        #if os(iOS)
        compact ? .principal : .topBarLeading
        #else
        .principal
        #endif
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: pickerPlacement) {
            // A segmented picker gets squeezed beside iPad's document title, so iOS uses a menu.
            if compact || isIOS {
                Menu {
                    Picker("View", selection: $controller.mode) {
                        ForEach(ViewMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                } label: {
                    Label(controller.mode.title, systemImage: controller.mode.symbol)
                        .labelStyle(.titleAndIcon)
                }
            } else {
                Picker("View", selection: $controller.mode) {
                    ForEach(ViewMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
            }
        }

        if compact {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    addButtons
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Menu {
                    if controller.mode == .gantt { outlineButtons; Divider(); zoomButtons }
                    if controller.mode == .resourcePlan {
                        usagePickers
                        Button("Copy Grid", systemImage: "doc.on.doc") { controller.copyResourcePlan() }
                    }
                    Divider()
                    toolsMenuContent
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                if controller.mode == .gantt {
                    Button("Add Task", systemImage: "plus") { controller.addTask() }
                        .help("Insert a task below the selection")
                    Button("Add Milestone", systemImage: "diamond") { controller.addTask(milestone: true) }
                    Button("Outdent", systemImage: "decrease.indent") { controller.outdent() }
                        .disabled(controller.selection.isEmpty)
                    Button("Indent", systemImage: "increase.indent") { controller.indent() }
                        .disabled(controller.selection.isEmpty)
                    Button("Link Tasks", systemImage: "link") { controller.linkSelection() }
                        .disabled(controller.selection.count < 2)
                        .help("Link the selected tasks finish-to-start")
                    Button("Delete", systemImage: "trash") { controller.deleteSelection() }
                        .disabled(controller.selection.isEmpty)
                } else {
                    Button("Add Resource", systemImage: "person.badge.plus") { controller.addResource() }
                    Button("Level Resources", systemImage: "chart.bar.xaxis") { controller.levelResources() }
                        .help("Delay tasks so nobody is overallocated")
                }
                if controller.mode == .resourcePlan {
                    Menu {
                        usagePickers
                    } label: {
                        Label(controller.usageTimescale.title, systemImage: "tablecells")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Columns and cell values")
                    Button("Copy Grid", systemImage: "doc.on.doc") { controller.copyResourcePlan() }
                        .help("Copy the resource plan to paste into Excel or Numbers")
                } else if controller.mode == .gantt {
                    Button("Zoom Out", systemImage: "minus.magnifyingglass") { controller.zoomOut() }
                    Button("Zoom In", systemImage: "plus.magnifyingglass") { controller.zoomIn() }
                }
                Button("Quick Plan", systemImage: "text.badge.plus") { controller.showQuickPlan = true }
                    .help("Jot tasks, durations and links as text, or have Claude plan them")
                Menu {
                    toolsMenuContent
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                Button("Inspector", systemImage: "sidebar.trailing") { controller.showInspector.toggle() }
            }
        }
    }

    @ViewBuilder
    private var addButtons: some View {
        if controller.mode == .gantt {
            Button("Task", systemImage: "plus") { controller.addTask() }
            Button("Milestone", systemImage: "diamond") { controller.addTask(milestone: true) }
        } else {
            Button("Resource", systemImage: "person.badge.plus") { controller.addResource() }
        }
        Button("Quick Plan…", systemImage: "text.badge.plus") { controller.showQuickPlan = true }
    }

    @ViewBuilder
    private var outlineButtons: some View {
        Button("Indent", systemImage: "increase.indent") { controller.indent() }
        Button("Outdent", systemImage: "decrease.indent") { controller.outdent() }
        Button("Move Up", systemImage: "arrow.up") { controller.moveUp() }
        Button("Move Down", systemImage: "arrow.down") { controller.moveDown() }
        Button("Link Selected", systemImage: "link") { controller.linkSelection() }
        Button("Delete", systemImage: "trash", role: .destructive) { controller.deleteSelection() }
    }

    @ViewBuilder
    private var usagePickers: some View {
        Picker("Columns", selection: $controller.usageTimescale) {
            ForEach(Timescale.allCases) { Text($0.title).tag($0) }
        }
        Picker("Show", selection: $controller.usageValue) {
            ForEach(UsageValue.allCases) { Text($0.title).tag($0) }
        }
    }

    @ViewBuilder
    private var zoomButtons: some View {
        Button("Zoom In", systemImage: "plus.magnifyingglass") { controller.zoomIn() }
        Button("Zoom Out", systemImage: "minus.magnifyingglass") { controller.zoomOut() }
    }

    @ViewBuilder
    private var toolsMenuContent: some View {
        Button("Level Resources", systemImage: "chart.bar.xaxis") { controller.levelResources() }
        Button("Clear Leveling", systemImage: "arrow.uturn.left") { controller.clearLeveling() }
        Divider()
        Toggle("Show Critical Path", systemImage: "point.topleft.down.to.point.bottomright.curvepath", isOn: $controller.showCriticalPath)
        Toggle("Show Baseline", systemImage: "rectangle.split.1x2", isOn: $controller.showBaseline)
        Button("Set Baseline", systemImage: "flag") { controller.setBaseline() }
        Button("Clear Baseline", systemImage: "flag.slash") { controller.clearBaseline() }
        Divider()
        Button("Project Information…", systemImage: "info.circle") { controller.showSettings = true }
        Button("Load Sample Project", systemImage: "doc.badge.gearshape") { controller.loadSample() }
    }
}
