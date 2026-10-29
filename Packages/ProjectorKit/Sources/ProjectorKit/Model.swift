import Foundation

/// How a successor's dates are tied to its predecessor's.
public enum DependencyType: String, Codable, CaseIterable, Sendable {
    case finishToStart = "FS"
    case startToStart = "SS"
    case finishToFinish = "FF"
    case startToFinish = "SF"

    public var title: String {
        switch self {
        case .finishToStart: "Finish-to-Start"
        case .startToStart: "Start-to-Start"
        case .finishToFinish: "Finish-to-Finish"
        case .startToFinish: "Start-to-Finish"
        }
    }
}

public struct Dependency: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var predecessorID: UUID
    public var successorID: UUID
    public var type: DependencyType
    /// Lag in working days; negative values are lead time.
    public var lag: Double

    public init(id: UUID = UUID(), predecessorID: UUID, successorID: UUID,
                type: DependencyType = .finishToStart, lag: Double = 0) {
        self.id = id
        self.predecessorID = predecessorID
        self.successorID = successorID
        self.type = type
        self.lag = lag
    }
}

public enum ConstraintType: String, Codable, CaseIterable, Sendable {
    case asSoonAsPossible
    /// Legacy: older files stored "start no earlier than" here. It is migrated to `ProjectTask.startAfter` on load.
    case startNoEarlierThan
    case mustStartOn

    /// The choices offered in the UI; earliest start and deadline are separate fields.
    public static let selectable: [ConstraintType] = [.asSoonAsPossible, .mustStartOn]

    public var title: String {
        switch self {
        case .asSoonAsPossible: "As Soon As Possible"
        case .startNoEarlierThan: "Start No Earlier Than"
        case .mustStartOn: "Must Start On"
        }
    }
}

public struct ProjectTask: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// 1-based outline level. A task followed by a deeper task is a summary task.
    public var outlineLevel: Int
    /// Duration in working days. Zero makes the task a milestone. Ignored for summary tasks.
    public var duration: Double
    public var constraint: ConstraintType
    public var constraintDate: Date?
    /// Earliest start ("starts after"). On a summary it holds back every subtask.
    public var startAfter: Date?
    /// Deadline ("must be completed before"). On a summary it applies to every subtask.
    /// It doesn't move the task; it pulls in late dates, so slack goes negative when the deadline is missed.
    public var finishBy: Date?
    /// 0...100
    public var percentComplete: Double
    public var notes: String
    /// Working days added by resource leveling.
    public var levelingDelay: Double
    public var baselineStart: Date?
    public var baselineFinish: Date?

    public init(id: UUID = UUID(), name: String, outlineLevel: Int = 1, duration: Double = 1,
                constraint: ConstraintType = .asSoonAsPossible, constraintDate: Date? = nil,
                percentComplete: Double = 0, notes: String = "", levelingDelay: Double = 0) {
        self.id = id
        self.name = name
        self.outlineLevel = outlineLevel
        self.duration = duration
        self.constraint = constraint
        self.constraintDate = constraintDate
        self.percentComplete = percentComplete
        self.notes = notes
        self.levelingDelay = levelingDelay
    }

    public var isMilestone: Bool { duration == 0 }

    /// `startAfter`, or a legacy Start-No-Earlier-Than constraint date.
    public var earliestStart: Date? {
        [startAfter, constraint == .startNoEarlierThan ? constraintDate : nil].compactMap { $0 }.max()
    }
}

public struct Resource: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var initials: String
    public var group: String
    /// 1.0 == 100% of one full-time person.
    public var maxUnits: Double
    /// Cost per working hour.
    public var standardRate: Double
    public var email: String

    public init(id: UUID = UUID(), name: String, initials: String? = nil, group: String = "",
                maxUnits: Double = 1, standardRate: Double = 0, email: String = "") {
        self.id = id
        self.name = name
        self.initials = initials ?? Resource.defaultInitials(for: name)
        self.group = group
        self.maxUnits = maxUnits
        self.standardRate = standardRate
        self.email = email
    }

    public static func defaultInitials(for name: String) -> String {
        name.split(separator: " ").compactMap(\.first).prefix(3).map(String.init).joined().uppercased()
    }
}

public struct Assignment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var taskID: UUID
    public var resourceID: UUID
    /// 1.0 == 100% of the resource's time.
    public var units: Double

    public init(id: UUID = UUID(), taskID: UUID, resourceID: UUID, units: Double = 1) {
        self.id = id
        self.taskID = taskID
        self.resourceID = resourceID
        self.units = units
    }
}

public struct CalendarSettings: Codable, Hashable, Sendable {
    /// `Calendar` weekday numbers: 1 = Sunday … 7 = Saturday.
    public var workingWeekdays: Set<Int>
    public var hoursPerDay: Double
    /// Non-working dates (start of day).
    public var holidays: [Date]

    public init(workingWeekdays: Set<Int> = [2, 3, 4, 5, 6], hoursPerDay: Double = 8, holidays: [Date] = []) {
        self.workingWeekdays = workingWeekdays
        self.hoursPerDay = hoursPerDay
        self.holidays = holidays
    }

    public var daysPerWeek: Double { Double(max(workingWeekdays.count, 1)) }
}

public struct Project: Codable, Hashable, Sendable {
    public var formatVersion: Int
    public var name: String
    public var manager: String
    public var startDate: Date
    public var calendar: CalendarSettings
    public var currencyCode: String
    /// Ordered outline, top to bottom, as in the Gantt table.
    public var tasks: [ProjectTask]
    public var resources: [Resource]
    public var assignments: [Assignment]
    public var dependencies: [Dependency]

    public init(name: String = "Untitled Project", manager: String = "",
                startDate: Date = Calendar.current.startOfDay(for: .now),
                calendar: CalendarSettings = CalendarSettings(), currencyCode: String = "USD",
                tasks: [ProjectTask] = [], resources: [Resource] = [],
                assignments: [Assignment] = [], dependencies: [Dependency] = []) {
        self.formatVersion = 1
        self.name = name
        self.manager = manager
        self.startDate = startDate
        self.calendar = calendar
        self.currencyCode = currencyCode
        self.tasks = tasks
        self.resources = resources
        self.assignments = assignments
        self.dependencies = dependencies
    }

    public func task(_ id: UUID) -> ProjectTask? { tasks.first { $0.id == id } }
    public func resource(_ id: UUID) -> Resource? { resources.first { $0.id == id } }
    public func index(of taskID: UUID) -> Int? { tasks.firstIndex { $0.id == taskID } }
}

// MARK: - Encoding

extension Project {
    public static func decode(from data: Data) throws -> Project {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var project = try decoder.decode(Project.self, from: data)
        for i in project.tasks.indices where project.tasks[i].constraint == .startNoEarlierThan {
            project.tasks[i].startAfter = project.tasks[i].startAfter ?? project.tasks[i].constraintDate
            project.tasks[i].constraint = .asSoonAsPossible
            project.tasks[i].constraintDate = nil
        }
        return project
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
