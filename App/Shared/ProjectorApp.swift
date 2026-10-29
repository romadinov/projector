import SwiftUI
import ProjectorKit

@main
struct ProjectorApp: App {
    var body: some Scene {
        #if os(iOS)
        DocumentGroupLaunchScene("Projector") {
            NewDocumentButton("New Project", source: .blank)
            NewDocumentButton("Sample Project", source: .sample)
        } background: {
            LinearGradient(colors: [Color(red: 0.16, green: 0.3, blue: 0.62), Color(red: 0.42, green: 0.2, blue: 0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
        #endif

        DocumentGroup { document in
            ProjectWindow(document: document)
        } makeDocument: { configuration, context in
            #if os(iOS)
            context.creationSource == .sample ? ProjectDocument(project: .sample()) : ProjectDocument()
            #else
            ProjectDocument()
            #endif
        }
        .commands { ProjectCommands() }
    }
}

#if os(iOS)
extension DocumentCreationSource {
    static let blank = DocumentCreationSource(id: "blank")
    static let sample = DocumentCreationSource(id: "sample")
}
#endif

/// Menu-bar (and iPad keyboard) commands for the focused project window.
struct ProjectCommands: Commands {
    @FocusedValue(ProjectController.self) private var controller

    var body: some Commands {
        CommandMenu("Task") { Group {
            Button("Insert Task") { controller?.addTask() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Insert Milestone") { controller?.addTask(milestone: true) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Quick Plan…") { controller?.showQuickPlan = true }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Indent") { controller?.indent() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Outdent") { controller?.outdent() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Move Up") { controller?.moveUp() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Move Down") { controller?.moveDown() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("Link Tasks") { controller?.linkSelection() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Unlink Tasks") { controller?.unlinkSelection() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Task Information") { controller?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Delete Task") { controller?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .disabled(controller == nil) }

        CommandMenu("Project") { Group {
            Button("Gantt Chart") { controller?.mode = .gantt }
                .keyboardShortcut("1", modifiers: .command)
            Button("Resource Plan") { controller?.mode = .resourcePlan }
                .keyboardShortcut("2", modifiers: .command)
            Button("Resource Sheet") { controller?.mode = .resourceSheet }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
            Button("Zoom In") { controller?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { controller?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
            Button("Level Resources") { controller?.levelResources() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Clear Leveling") { controller?.clearLeveling() }
            Button("Set Baseline") { controller?.setBaseline() }
            Divider()
            Button("Project Information…") { controller?.showSettings = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        .disabled(controller == nil) }
    }
}
