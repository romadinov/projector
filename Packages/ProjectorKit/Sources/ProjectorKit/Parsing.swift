import Foundation

/// MS Project-style text entry: "5d", "2w", "4h"; predecessors "3FS+2d, 5SS"; resources "Ann, Bob[50%]".
public enum Notation {
    // MARK: Durations

    public static func parseDuration(_ text: String, settings: CalendarSettings) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "?", with: "")
        guard !s.isEmpty else { return nil }
        let numberPart = s.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard let value = Double(numberPart.replacingOccurrences(of: ",", with: ".")), value >= 0 else { return nil }
        let unit = s.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)
        switch unit {
        case "", "d", "dy", "day", "days": return value
        case "w", "wk", "wks", "week", "weeks": return value * settings.daysPerWeek
        case "h", "hr", "hrs", "hour", "hours": return value / max(settings.hoursPerDay, 1)
        case "mo", "mon", "mons", "month", "months": return value * settings.daysPerWeek * 4
        default: return nil
        }
    }

    public static func formatDuration(_ days: Double) -> String {
        let value = formatNumber(days)
        return days == 1 ? "1 day" : "\(value) days"
    }

    public static func formatNumber(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    // MARK: Predecessors

    public struct PredecessorSpec: Equatable, Sendable {
        public var row: Int
        public var type: DependencyType
        public var lag: Double

        public init(row: Int, type: DependencyType = .finishToStart, lag: Double = 0) {
            self.row = row
            self.type = type
            self.lag = lag
        }
    }

    /// Parses a comma/semicolon separated list of `<row>[type][±lag]`. Returns nil on syntax errors.
    public static func parsePredecessors(_ text: String, settings: CalendarSettings) -> [PredecessorSpec]? {
        var specs: [PredecessorSpec] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            var token = raw.replacingOccurrences(of: " ", with: "").uppercased()[...]
            guard !token.isEmpty else { continue }
            let digits = token.prefix { $0.isNumber }
            guard let row = Int(digits) else { return nil }
            token = token.dropFirst(digits.count)
            var type = DependencyType.finishToStart
            if let t = DependencyType(rawValue: String(token.prefix(2))) {
                type = t
                token = token.dropFirst(2)
            }
            var lag = 0.0
            if let sign = token.first, sign == "+" || sign == "-" {
                guard let amount = parseDuration(String(token.dropFirst()), settings: settings) else { return nil }
                lag = sign == "-" ? -amount : amount
            } else if !token.isEmpty {
                return nil
            }
            specs.append(PredecessorSpec(row: row, type: type, lag: lag))
        }
        return specs
    }

    public static func formatPredecessors(of taskID: UUID, in project: Project, outline: Outline) -> String {
        project.dependencies
            .filter { $0.successorID == taskID }
            .compactMap { d -> (Int, String)? in
                guard let row = outline.rowIndex[d.predecessorID] else { return nil }
                return (row, formatPredecessor(row: row + 1, type: d.type, lag: d.lag))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
            .joined(separator: ",")
    }

    public static func formatPredecessor(row: Int, type: DependencyType, lag: Double) -> String {
        var s = "\(row)"
        if type != .finishToStart || lag != 0 { s += type.rawValue }
        if lag != 0 { s += (lag > 0 ? "+" : "-") + formatNumber(abs(lag)) + "d" }
        return s
    }

    // MARK: Resource names

    public struct ResourceSpec: Equatable, Sendable {
        public var name: String
        public var units: Double
    }

    public static func parseResources(_ text: String) -> [ResourceSpec]? {
        var specs: [ResourceSpec] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if let open = item.firstIndex(of: "["), item.hasSuffix("]") {
                let name = item[..<open].trimmingCharacters(in: .whitespaces)
                let inner = item[item.index(after: open)..<item.index(before: item.endIndex)]
                    .replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, let percent = Double(inner), percent > 0 else { return nil }
                specs.append(ResourceSpec(name: name, units: percent / 100))
            } else {
                specs.append(ResourceSpec(name: item, units: 1))
            }
        }
        return specs
    }

    public static func formatResources(of taskID: UUID, in project: Project) -> String {
        project.assignments
            .filter { $0.taskID == taskID }
            .compactMap { a -> String? in
                guard let r = project.resource(a.resourceID) else { return nil }
                return abs(a.units - 1) < 1e-9 ? r.name : "\(r.name)[\(formatNumber(a.units * 100))%]"
            }
            .joined(separator: ", ")
    }

    public static func formatPercent(_ units: Double) -> String { "\(formatNumber(units * 100))%" }

    // MARK: Dates

    /// Parses "2026-11-10" as the start of that day in the local time zone.
    public static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = trimmed.split(separator: "-").compactMap { Int($0) }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: .current) else { return nil }
        return Calendar.current.date(from: components)
    }

    public static func formatDate(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
