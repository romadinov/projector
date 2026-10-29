import Foundation

/// A plain-text notation for jotting down a plan, one task per line:
///
///     Discovery
///       Kickoff 0d @Priya
///       Interviews 4d after Kickoff @Priya, @Diego[50%]
///       Audit 3d after Kickoff SS+1d
///     Build 2w after Discovery
///
/// - Indentation (2 spaces or a tab per level) builds the WBS; a line with deeper lines below it is a summary.
/// - A duration (`5d`, `2w`, `4h`, `0d` for a milestone) may follow the name. Default is 1 day.
/// - `after A, B SS+2d, 3` links to earlier tasks by name (exact, then prefix, then substring) or by line number.
/// - `after 2026-11-10` holds a task (or a whole phase) back until that date; dates mix with task references.
/// - `by 2026-12-15` sets a deadline the task (or every subtask of a phase) should finish on or before.
/// - `@Name` or `@Name[50%]` assigns resources; use `_` for spaces (`@Priya_Shah`). Unknown names become new resources.
/// - Lines starting with `#` or `//` are comments; leading `-`, `*`, or `•` bullets are ignored.
public enum QuickPlan {
    public struct Result: Sendable {
        public var project: Project
        public var warnings: [String]
    }

    struct Line {
        var number: Int
        var depth: Int
        var name: String
        var duration: Double?
        var refs: [String]
        var startAfter: Date?
        var finishBy: Date?
        var resources: [Notation.ResourceSpec]
    }

    /// Parses `text` into tasks appended to `base` (pass a fresh project to build from scratch).
    public static func parse(_ text: String, into base: Project) -> Result {
        var warnings: [String] = []
        var lines: [Line] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            guard let line = parseLine(raw, number: i + 1, settings: base.calendar, warnings: &warnings) else { continue }
            lines.append(line)
        }

        var project = base
        let offset = project.tasks.count
        // Indentation depth -> outline level relative to the shallowest line.
        let minDepth = lines.map(\.depth).min() ?? 0
        var tasks: [ProjectTask] = []
        for line in lines {
            var task = ProjectTask(name: line.name, outlineLevel: line.depth - minDepth + 1,
                                   duration: line.duration ?? 1)
            task.startAfter = line.startAfter
            task.finishBy = line.finishBy
            tasks.append(task)
        }
        project.tasks += tasks
        project.normalizeOutline()
        let outline = Outline(tasks: project.tasks)

        for (i, line) in lines.enumerated() {
            let task = project.tasks[offset + i]
            if outline.isSummary(task.id), line.duration != nil {
                warnings.append("Line \(line.number): “\(line.name)” has subtasks, so its duration is calculated.")
            }
            for ref in line.refs {
                let (target, type, lag) = splitReference(ref, settings: base.calendar)
                guard let predIndex = resolve(target, among: lines, before: i, offset: offset) else {
                    warnings.append("Line \(line.number): no earlier task matches “\(target)”.")
                    continue
                }
                let pred = project.tasks[predIndex]
                do {
                    try project.addDependency(Dependency(predecessorID: pred.id, successorID: task.id, type: type, lag: lag))
                } catch {
                    warnings.append("Line \(line.number): \(error.localizedDescription)")
                }
            }
            if !line.resources.isEmpty {
                let text = line.resources
                    .map { abs($0.units - 1) < 1e-9 ? $0.name : "\($0.name)[\(Notation.formatNumber($0.units * 100))%]" }
                    .joined(separator: ", ")
                try? project.setResources(of: task.id, text: text)
            }
        }
        return Result(project: project, warnings: warnings)
    }

    static func parseLine(_ raw: String, number: Int, settings: CalendarSettings, warnings: inout [String]) -> Line? {
        var depth = 0
        var body = Substring(raw)
        while let c = body.first, c == " " || c == "\t" {
            depth += c == "\t" ? 2 : 1
            body = body.dropFirst()
        }
        depth /= 2
        var text = body.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("#") || text.hasPrefix("//") { return nil }
        for bullet in ["- ", "* ", "• ", "– "] where text.hasPrefix(bullet) {
            text = String(text.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
        }

        // Resources: @Name or @Name[50%], anywhere on the line.
        var resources: [Notation.ResourceSpec] = []
        var kept: [String] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if word.hasPrefix("@"), word.count > 1 {
                let spec = String(word.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: ","))
                if let parsed = Notation.parseResources(spec.replacingOccurrences(of: "_", with: " ")) {
                    resources += parsed
                }
            } else {
                kept.append(String(word))
            }
        }
        text = kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))

        // Deadline: "by 2026-12-15", anywhere on the line.
        var finishBy: Date?
        if let range = text.range(of: #"\s+by\s+\d{4}-\d{1,2}-\d{1,2}\b"#, options: [.regularExpression, .caseInsensitive]) {
            let token = text[range].split(separator: " ").last.map(String.init) ?? ""
            finishBy = Notation.parseDate(token)
            text.removeSubrange(range)
        }

        // Dependencies after the keyword "after".
        var refs: [String] = []
        var startAfter: Date?
        if let range = text.range(of: #"\s+after\s+"#, options: [.regularExpression, .caseInsensitive]) {
            refs = text[range.upperBound...]
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .flatMap { $0.components(separatedBy: " and ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            refs.removeAll { ref in
                guard let date = Notation.parseDate(ref) else { return false }
                startAfter = max(startAfter ?? date, date)
                return true
            }
            text = String(text[..<range.lowerBound])
        }

        // Trailing duration token, optionally in parentheses: "Build (5d)" or "Build 5d".
        var duration: Double?
        var words = text.split(separator: " ").map(String.init)
        if let last = words.last {
            let token = last.trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
            // A bare number ("Phase 2") is part of the name; durations need a unit.
            if words.count > 1, token.first?.isNumber == true, token.last?.isLetter == true,
               let d = Notation.parseDuration(token, settings: settings) {
                duration = d
                words.removeLast()
            } else if words.count > 2, last.first?.isLetter == true,
                      let d = Notation.parseDuration(words[words.count - 2] + last, settings: settings),
                      words[words.count - 2].first?.isNumber == true {
                // "Build 2 weeks"
                duration = d
                words.removeLast(2)
            }
        }
        if words.last?.lowercased() == "milestone" || words.last == "◆" {
            words.removeLast()
            duration = 0
        }
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            warnings.append("Line \(number): missing task name.")
            return nil
        }
        return Line(number: number, depth: depth, name: name, duration: duration, refs: refs,
                    startAfter: startAfter, finishBy: finishBy, resources: resources)
    }

    /// Splits "Design SS+2d" into ("Design", .startToStart, 2).
    static func splitReference(_ ref: String, settings: CalendarSettings) -> (String, DependencyType, Double) {
        let pattern = #"^(.*?)\s*\b(FS|SS|FF|SF)?\s*(([+-])\s*([0-9.]+\s*[a-zA-Z]*))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: ref, range: NSRange(ref.startIndex..., in: ref)) else {
            return (ref, .finishToStart, 0)
        }
        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: ref) else { return nil }
            return String(ref[r])
        }
        let target = (group(1) ?? ref).trimmingCharacters(in: .whitespaces)
        let type = group(2).flatMap { DependencyType(rawValue: $0) } ?? .finishToStart
        var lag = 0.0
        if let amount = group(5), let value = Notation.parseDuration(amount, settings: settings) {
            lag = group(4) == "-" ? -value : value
        }
        return (target.isEmpty ? ref : target, type, lag)
    }

    /// Resolves a reference to a task index in the combined project task list.
    static func resolve(_ target: String, among lines: [Line], before index: Int, offset: Int) -> Int? {
        if let number = Int(target) {
            // A number refers to the n-th task line of this plan.
            return number >= 1 && number <= lines.count && number - 1 != index ? offset + number - 1 : nil
        }
        let key = target.lowercased()
        let candidates = Array(lines.enumerated()).filter { $0.offset != index }
        let earlierFirst = candidates.filter { $0.offset < index } + candidates.filter { $0.offset > index }
        for matcher in [{ (n: String) in n == key }, { $0.hasPrefix(key) }, { $0.contains(key) }] {
            if let hit = earlierFirst.first(where: { matcher($0.element.name.lowercased()) }) {
                return offset + hit.offset
            }
        }
        return nil
    }

    /// Renders an existing project back into Quick Plan text, so a plan can round-trip through the editor.
    public static func render(_ project: Project) -> String {
        let outline = Outline(tasks: project.tasks)
        var nameCounts: [String: Int] = [:]
        for t in project.tasks { nameCounts[t.name.lowercased(), default: 0] += 1 }
        var lines: [String] = []
        for task in project.tasks {
            let depth = (outline.level[task.id] ?? 1) - 1
            var line = String(repeating: "  ", count: depth) + task.name
            if !outline.isSummary(task.id) { line += " " + Notation.formatNumber(task.duration) + "d" }
            let preds = project.dependencies.filter { $0.successorID == task.id }.compactMap { d -> String? in
                guard let p = project.task(d.predecessorID), let row = outline.rowIndex[p.id] else { return nil }
                // Names are friendlier; fall back to line numbers for duplicate names.
                var ref = nameCounts[p.name.lowercased()] == 1 && !p.name.contains(",") ? p.name : "\(row + 1)"
                if d.type != .finishToStart || d.lag != 0 { ref += " " + d.type.rawValue }
                if d.lag != 0 { ref += (d.lag > 0 ? "+" : "-") + Notation.formatNumber(abs(d.lag)) + "d" }
                return ref
            }
            let afters = (task.earliestStart.map { [Notation.formatDate($0)] } ?? []) + preds
            if !afters.isEmpty { line += " after " + afters.joined(separator: ", ") }
            if let deadline = task.finishBy { line += " by " + Notation.formatDate(deadline) }
            for a in project.assignments where a.taskID == task.id {
                guard let r = project.resource(a.resourceID) else { continue }
                line += " @" + r.name.replacingOccurrences(of: " ", with: "_")
                if abs(a.units - 1) > 1e-9 { line += "[\(Notation.formatNumber(a.units * 100))%]" }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
