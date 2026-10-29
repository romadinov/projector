import Foundation
import Security
import ProjectorKit

/// Turns rough notes into a plan in Quick Plan notation using the Claude API.
///
/// Swift has no official Anthropic SDK, so this calls the Messages API over HTTPS directly.
/// Claude answers in the same text notation the editor already parses, so the person can review
/// and tweak the plan before applying it.
struct ClaudePlanner {
    static let model = "claude-opus-5-5"

    enum PlannerError: LocalizedError {
        case missingKey
        case http(Int, String)
        case refused(String?)
        case truncated
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .missingKey: "Add your Claude API key first."
            case .http(401, _): "The Claude API key was rejected. Check it in the key field."
            case .http(429, _): "Claude is rate-limiting requests right now. Try again in a minute."
            case .http(let code, let message) where code >= 500: "Claude is temporarily unavailable (\(code)). \(message)"
            case .http(let code, let message): "Claude request failed (\(code)): \(message)"
            case .refused(let explanation): "Claude declined to plan this." + (explanation.map { " \($0)" } ?? "")
            case .truncated: "The plan was too long to finish. Try planning one phase at a time."
            case .emptyResponse: "Claude returned an empty plan."
            }
        }
    }

    let apiKey: String

    func plan(notes: String, project: Project) async throws -> String {
        guard !apiKey.isEmpty else { throw PlannerError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Lets the API retry a declined request on its recommended fallback model.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "high"],
            "fallbacks": "default",
            "system": Self.systemPrompt(for: project),
            "messages": [["role": "user", "content": notes]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data, as: UTF8.self)
            throw PlannerError.http(status, message)
        }
        switch json["stop_reason"] as? String {
        case "refusal":
            throw PlannerError.refused((json["stop_details"] as? [String: Any])?["explanation"] as? String)
        case "max_tokens":
            throw PlannerError.truncated
        default:
            break
        }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        let plan = Self.stripFences(text)
        guard !plan.isEmpty else { throw PlannerError.emptyResponse }
        return plan
    }

    static func stripFences(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        if let open = lines.firstIndex(where: { $0.hasPrefix("```") }),
           let close = lines.lastIndex(where: { $0.hasPrefix("```") }), close > open {
            lines = Array(lines[(open + 1)..<close])
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func systemPrompt(for project: Project) -> String {
        let start = project.startDate.formatted(date: .complete, time: .omitted)
        let resources = project.resources.isEmpty ? "none yet" :
            project.resources.map { "\($0.name) (\(Notation.formatPercent($0.maxUnits)) available)" }.joined(separator: ", ")
        return """
        You are an experienced project scheduler working inside a Microsoft Project–style planning app. \
        The person gives you rough notes: a list of things to do, maybe with lengths, ordering and people. \
        Turn them into a complete, realistic work breakdown structure written in the app's plain-text plan notation, \
        which the app parses and schedules with the critical path method.

        The notation, one task per line:
        - Indent two spaces per level to build the WBS. A line with more-indented lines below it is a summary \
        (phase); don't give summaries a duration — the app rolls it up.
        - After the name, an optional duration with a unit: 3d (working days), 2w (weeks), 4h (hours). \
        Use 0d for milestones. A bare number is treated as part of the name, so always include the unit.
        - Dependencies: "after <task name>" (or several separated by commas). Default link is finish-to-start. \
        Add a type and lag after a name when needed: "after Design SS+2d", "after Build FF", "after Pour concrete +3d". \
        Reference earlier task names exactly as written; names must be unique.
        - Date limits, on tasks or phases: "after 2026-11-16" (can't start before that date; mix with task names, \
        e.g. "after Design, 2026-11-16") and "by 2026-12-18" (deadline: should finish on or before). \
        Use them only for dates the person mentions (go-lives, holidays, supplier deliveries, launch dates).
        - Resources: "@Name" or "@Name[50%]" for part-time; use underscores for spaces (@Priya_Shah).
        - Lines starting with # are comments.

        Example:
        Discovery
          Kickoff 0d @Priya
          Stakeholder interviews 4d after Kickoff @Priya, @Diego[50%]
          Content audit 3d after Kickoff SS+1d @Diego
        Build
          Front end 3w after Discovery @Mei
          QA 1w after Front end @Sara by 2026-12-18

        Guidelines:
        - Keep everything the person wrote: their task names, durations, order constraints and people take precedence. \
        Fill gaps with sensible estimates and add obviously missing steps (reviews, approvals, testing, sign-off milestones), \
        but don't pad the plan.
        - Link tasks so the network has no dangling work: every task should lead somewhere, ending at a final milestone. \
        Parallelize work that doesn't truly depend on each other, so the critical path is honest.
        - Only assign people the person mentioned or who already exist in the project. Prefer not to overload one person \
        with parallel full-time tasks.
        - Group work into a small number of phases.
        - If the notes already are a plan in this notation, revise it as asked rather than starting over.

        Context: the project starts \(start). Existing resources: \(resources).

        Reply with only the plan in the notation — no explanations, no Markdown fences. \
        If you need to note an assumption, put it on a # comment line.
        """
    }
}

/// Stores the Claude API key in the keychain.
enum APIKeyStore {
    private static let service = "com.ideahelix.projector.claude"
    private static let account = "api-key"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    }

    static func save(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
