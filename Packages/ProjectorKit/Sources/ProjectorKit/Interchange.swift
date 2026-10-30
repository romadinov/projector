import Foundation

/// File formats other planning tools read and write.
public enum InterchangeFormat: String, CaseIterable, Identifiable, Sendable {
    /// Microsoft Project XML (MSPDI), which every version of MS Project since 2002 opens and saves.
    case msProject
    /// Primavera P6 XER, the text export P6 Professional and EPPM import.
    case primavera

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .msProject: "Microsoft Project XML"
        case .primavera: "Primavera P6 XER"
        }
    }

    public var fileExtension: String {
        switch self {
        case .msProject: "xml"
        case .primavera: "xer"
        }
    }
}

public struct ImportResult: Sendable {
    public var project: Project
    /// Things that didn't carry over exactly.
    public var warnings: [String]
}

public enum InterchangeError: LocalizedError {
    case unrecognized
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognized: "This isn't a Microsoft Project XML or Primavera XER file."
        case .malformed(let detail): "The file couldn't be read: \(detail)"
        }
    }
}

public enum Interchange {
    /// Reads an MS Project XML or Primavera XER file, telling them apart by content.
    public static func importFile(_ data: Data) throws -> ImportResult {
        let head = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
        if head.hasPrefix("ERMHDR") { return try PrimaveraXER.import(data) }
        if head.hasPrefix("<") { return try MSProjectXML.import(data) }
        throw InterchangeError.unrecognized
    }

    public static func export(_ project: Project, as format: InterchangeFormat) -> Data {
        switch format {
        case .msProject: MSProjectXML.export(project)
        case .primavera: PrimaveraXER.export(project)
        }
    }
}

// MARK: - Time of day

/// Both formats store date-times, while Projector schedules in working days. An exported day starts
/// at 08:00, with an hour's lunch at noon when the day is 8 hours long, as MS Project and P6 default to.
struct WorkingDay {
    let hours: Double

    var periods: [(from: Double, to: Double)] {
        hours == 8 ? [(8, 12), (13, 17)] : [(8, min(8 + hours, 24))]
    }

    var endHour: Double { periods.last!.to }

    /// Hour of the day once `worked` working hours have passed.
    func clock(afterWorking worked: Double) -> Double {
        var left = max(worked, 0)
        for p in periods {
            if left <= p.to - p.from + 1e-9 { return p.from + left }
            left -= p.to - p.from
        }
        return endHour
    }

    /// When an activity starting at scheduler offset `offset` begins.
    func start(_ offset: Double, on calendar: WorkCalendar) -> Date {
        let day = Int((offset + 1e-9).rounded(.down))
        return at(calendar.date(forDay: day), hour: clock(afterWorking: (offset - Double(day)) * hours), calendar.calendar)
    }

    /// When an activity ending at scheduler offset `offset` ends (the end of the previous working day for whole days).
    func finish(_ offset: Double, on calendar: WorkCalendar) -> Date {
        let day = WorkCalendar.finishDayIndex(offset)
        let worked = offset <= 0 ? 0 : (offset - Double(day)) * hours
        return at(calendar.date(forDay: day), hour: clock(afterWorking: worked), calendar.calendar)
    }

    func at(_ day: Date, hour: Double, _ calendar: Calendar) -> Date {
        let minutes = Int((hour * 60).rounded())
        return calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: day))!
    }

    /// The working day a start date-time falls on: a start at or after the end of the day means the next day.
    func startDay(_ date: Date, _ calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        return hourOfDay(date, calendar) >= endHour - 1e-6 ? calendar.date(byAdding: .day, value: 1, to: day)! : day
    }

    /// The working day a finish date-time falls on: midnight means the end of the day before.
    func finishDay(_ date: Date, _ calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        return hourOfDay(date, calendar) <= 1e-6 ? calendar.date(byAdding: .day, value: -1, to: day)! : day
    }

    private func hourOfDay(_ date: Date, _ calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }
}

// MARK: - Date-time text

enum DateText {
    /// Parses `yyyy-MM-dd`, `yyyy-MM-dd HH:mm` and `yyyy-MM-ddTHH:mm:ss` as local time.
    static func parse(_ text: String?, _ calendar: Calendar = .current) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 3 else { return nil }
        var c = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])
        if numbers.count >= 5 { c.hour = numbers[3]; c.minute = numbers[4] }
        if numbers.count >= 6 { c.second = numbers[5] }
        return calendar.date(from: c)
    }

    /// `yyyy-MM-ddTHH:mm:ss` (MS Project) or `yyyy-MM-dd HH:mm` (P6).
    static func format(_ date: Date, seconds: Bool, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        return seconds
            ? day + String(format: "T%02d:%02d:%02d", c.hour!, c.minute!, c.second!)
            : day + String(format: " %02d:%02d", c.hour!, c.minute!)
    }
}

/// A number without trailing zeros, always with a dot.
func plainNumber(_ value: Double) -> String {
    if abs(value - value.rounded()) < 1e-9 { return String(Int(value.rounded())) }
    var text = String(format: "%.4f", value)
    while text.hasSuffix("0") { text.removeLast() }
    return text
}

// MARK: - Minimal XML

final class MarkupNode {
    let name: String
    var children: [MarkupNode] = []
    var text = ""

    init(name: String) { self.name = name }

    func first(_ name: String) -> MarkupNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [MarkupNode] { children.filter { $0.name == name } }
    /// Trimmed text of the first child element called `name`, or nil when it is missing or empty.
    func value(_ name: String) -> String? {
        guard let text = first(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
    func number(_ name: String) -> Double? { value(name).flatMap(Double.init) }
    func int(_ name: String) -> Int? { value(name).flatMap { Int($0) ?? Double($0).map { Int($0) } } }
    func flag(_ name: String) -> Bool { value(name) == "1" || value(name)?.lowercased() == "true" }

    static func parse(_ data: Data) throws -> MarkupNode {
        let builder = MarkupTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw InterchangeError.malformed(parser.parserError?.localizedDescription ?? "not XML")
        }
        return root
    }
}

private final class MarkupTreeBuilder: NSObject, XMLParserDelegate {
    var root: MarkupNode?
    private var stack: [MarkupNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let node = MarkupNode(name: local)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}

struct MarkupWriter {
    private(set) var text = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private var depth = 0

    mutating func open(_ name: String, attributes: String = "") {
        text += String(repeating: "  ", count: depth) + "<\(name)\(attributes.isEmpty ? "" : " " + attributes)>\n"
        depth += 1
    }

    mutating func close(_ name: String) {
        depth -= 1
        text += String(repeating: "  ", count: depth) + "</\(name)>\n"
    }

    /// Writes `<name>value</name>`; nothing when the value is nil.
    mutating func element(_ name: String, _ value: String?) {
        guard let value else { return }
        text += String(repeating: "  ", count: depth) + "<\(name)>\(Self.escape(value))</\(name)>\n"
    }

    mutating func element(_ name: String, _ value: Int) { element(name, String(value)) }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
