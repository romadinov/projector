import SwiftUI
import UniformTypeIdentifiers
import ProjectorKit

extension UTType {
    static let projectorPlan = UTType(exportedAs: "com.ideahelix.projector.plan")
}

/// A `.projector` file: the project serialized as JSON.
@Observable
final class ProjectDocument: Document {
    static let readableContentTypes: [UTType] = [.projectorPlan]

    var project: Project {
        didSet { schedule = Scheduler.schedule(project) }
    }
    private(set) var schedule: Schedule

    init(project: Project = Project()) {
        self.project = project
        self.schedule = Scheduler.schedule(project)
    }

    func reader(configuration: sending ReadConfiguration) -> sending FileWrapperDocumentReader<Project> {
        FileWrapperDocumentReader(configuration) { fileWrapper in
            guard let data = fileWrapper.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            return try Project.decode(from: data)
        }
    }

    @MainActor
    func apply(snapshot: sending Project, previous: sending Project?) async throws {
        project = snapshot
    }

    func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<Project> {
        FileWrapperDocumentWriter(configuration) { snapshot, _ in
            FileWrapper(regularFileWithContents: try snapshot.encoded())
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending Project {
        project
    }
}
