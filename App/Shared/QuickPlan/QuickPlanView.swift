import SwiftUI
import ProjectorKit

/// Jot a plan down as text — names, lengths, "after" links, @people — preview its schedule and
/// critical path, optionally let Claude flesh it out, then apply it.
struct QuickPlanView: View {
    let controller: ProjectController
    @Environment(\.dismiss) private var dismiss

    enum ApplyMode: String, CaseIterable, Identifiable {
        case replace, append
        var id: String { rawValue }
        var title: String { self == .replace ? "Replace plan" : "Add to plan" }
    }

    @State private var text = ""
    @State private var mode: ApplyMode = .replace
    @State private var apiKey = APIKeyStore.load()
    @State private var editingKey = false
    @State private var planning = false
    @State private var plannerError: String?
    @State private var textBeforeClaude: String?
    @State private var showHelp = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// On iPhone the header only has room for Cancel and Apply.
    private var claudePlacement: ToolbarItemPlacement {
        #if os(iOS)
        sizeClass == .compact ? .bottomBar : .primaryAction
        #else
        .primaryAction
        #endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editor
                Divider()
                PlanPreview(result: preview, project: controller.project)
                    .frame(maxHeight: 220)
            }
            .navigationTitle("Quick Plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .sheet(isPresented: $editingKey) { keyEditor }
            .alert("Couldn't Plan", isPresented: Binding(get: { plannerError != nil }, set: { if !$0 { plannerError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(plannerError ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 560)
        #endif
        .onAppear {
            // An empty project starts with an empty editor; the template is only a placeholder.
            if !controller.project.tasks.isEmpty {
                text = QuickPlan.render(controller.project)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("One task per line. Indent for phases. `5d`, `2w`, `0d` milestone · `after Task SS+2d` · `@Name[50%]`")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(showHelp ? "Hide help" : "Help") { showHelp.toggle() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            if showHelp {
                Text(Self.help)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .disabled(planning)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Self.template)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if planning {
                        ProgressView("Claude is planning…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
        }
        .padding()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Apply") { apply() }
                .disabled(planning || preview.project.tasks.count == base.tasks.count)
        }
        ToolbarItemGroup(placement: claudePlacement) {
            if !controller.project.tasks.isEmpty {
                Picker("Mode", selection: $mode) {
                    ForEach(ApplyMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: mode) { _, newMode in
                    if newMode == .append && text == QuickPlan.render(controller.project) { text = "" }
                    if newMode == .replace && text.isEmpty { text = QuickPlan.render(controller.project) }
                }
            }
            Menu {
                Button("Plan with Claude", systemImage: "sparkles") { Task { await planWithClaude() } }
                if let previous = textBeforeClaude {
                    Button("Revert to My Notes", systemImage: "arrow.uturn.backward") {
                        text = previous
                        textBeforeClaude = nil
                    }
                }
                Divider()
                Button(apiKey.isEmpty ? "Add Claude API Key…" : "Change Claude API Key…", systemImage: "key") { editingKey = true }
            } label: {
                Label("Plan with Claude", systemImage: "sparkles")
            } primaryAction: {
                Task { await planWithClaude() }
            }
            .disabled(planning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send these notes to Claude to build out the WBS, durations, links and assignments")
        }
    }

    private var keyEditor: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text("Create a key at console.anthropic.com. It's stored in this device's keychain and only sent to api.anthropic.com. Your plan notes and the project's resource names are sent to Claude when you choose Plan with Claude.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Claude API Key")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        APIKeyStore.save(apiKey)
                        editingKey = false
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { apiKey = APIKeyStore.load(); editingKey = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 220)
        #endif
    }

    /// The project the plan is parsed into: an emptied copy (keeping settings and resources) or the current one.
    private var base: Project {
        var p = controller.project
        if mode == .replace {
            p.tasks = []
            p.dependencies = []
            p.assignments = []
        }
        return p
    }

    private var preview: QuickPlan.Result {
        QuickPlan.parse(text, into: base)
    }

    private func apply() {
        let result = preview
        controller.edit(mode == .replace ? "Quick Plan" : "Add Tasks from Quick Plan") { $0 = result.project }
        controller.collapsed = []
        controller.selection = []
        controller.mode = .gantt
        dismiss()
    }

    private func planWithClaude() async {
        if apiKey.isEmpty {
            editingKey = true
            return
        }
        planning = true
        defer { planning = false }
        do {
            let notes = text
            let plan = try await ClaudePlanner(apiKey: apiKey).plan(notes: notes, project: base)
            textBeforeClaude = notes
            text = plan
        } catch {
            plannerError = error.localizedDescription
        }
    }

    static let template = """
    # Jot your plan here, then Apply — or press Plan with Claude to flesh it out.
    # Indent for phases. Durations: 5d, 2w, 4h, 0d = milestone.
    # Links: after <task>[, <task> SS+2d]. People: @Name or @Name[50%].
    Design
      Requirements 3d @Alex
      Mockups 1w after Requirements @Sam
      Design sign-off 0d after Mockups
    Build
      Backend 2w after Requirements @Jo
      Frontend 2w after Design sign-off @Sam
    Launch 0d after Backend, Frontend
    """

    static let help = """
    Phase                       a line with indented lines under it is a summary
      Task name 5d              durations: 5d · 2w · 4h · 1.5d · 0d (milestone)
      Task B 3d after Task name finish-to-start link by name (or line number)
      Task C 2d after B SS+1d   types FS SS FF SF, lag +2d / lead -1d
      Task D 4d @Ann @Bob[50%]  resources; unknown names are added to the sheet
    # comment                   ignored
    """
}

/// Live schedule summary of the plan being typed: tasks, finish date, critical path, warnings.
private struct PlanPreview: View {
    let result: QuickPlan.Result
    let project: Project

    var body: some View {
        let schedule = Scheduler.schedule(result.project)
        let leaves = result.project.tasks.filter { !schedule.outline.isSummary($0.id) }
        let critical = leaves.filter { schedule[$0.id]?.isCritical == true }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    stat("Tasks", "\(result.project.tasks.count)")
                    stat("Links", "\(result.project.dependencies.count)")
                    stat("Duration", Notation.formatDuration(schedule.durationDays))
                    stat("Finish", schedule.projectFinish.formatted(date: .abbreviated, time: .omitted))
                    stat("People", "\(result.project.resources.count)")
                }
                if !critical.isEmpty {
                    Label {
                        Text(critical.map(\.name).joined(separator: " → "))
                    } icon: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(GanttRenderer.criticalColor)
                    }
                    .font(.callout)
                    .help("Critical path")
                }
                let late = leaves.filter { schedule[$0.id]?.missesDeadline == true }
                if !late.isEmpty {
                    Label("Misses a deadline: " + late.map { t in
                        "\(t.name) (\(Notation.formatDuration(-(schedule[t.id]?.totalSlack ?? 0))) late)"
                    }.joined(separator: ", "), systemImage: "exclamationmark.circle.fill")
                        .font(.callout).foregroundStyle(GanttRenderer.criticalColor)
                }
                let overloaded = result.project.resources.filter { schedule.resourceLoads[$0.id]?.isOverallocated == true }
                if !overloaded.isEmpty {
                    Label("Overallocated: \(overloaded.map(\.name).joined(separator: ", ")) — you can level resources after applying.",
                          systemImage: "person.fill.xmark")
                        .font(.callout).foregroundStyle(.orange)
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(.bar)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }
}
