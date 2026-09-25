import Foundation

/// Local answer drafts are distinct from delivery: copying never marks a question handled.
public struct QuickAnswerDrafts: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var answers: [String: String] = [:]
        public var handled = false
        public var updatedAt = Date()
        public init() {}
    }

    public private(set) var entries: [String: Entry] = [:]
    public private(set) var attachedPlans: [String: [String]] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey { case entries, attachedPlans }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        attachedPlans = try container.decodeIfPresent([String: [String]].self, forKey: .attachedPlans) ?? [:]
    }

    public mutating func attach(path: String, sessionID: String) {
        var paths = attachedPlans[sessionID] ?? []
        if !paths.contains(path) { paths.append(path) }
        attachedPlans[sessionID] = Array(paths.suffix(20))
    }

    public func answer(sourceID: String, questionID: String) -> String {
        entries[sourceID]?.answers[questionID] ?? ""
    }

    public func isHandled(_ sourceID: String) -> Bool { entries[sourceID]?.handled == true }

    public mutating func setAnswer(_ text: String, sourceID: String, questionID: String) {
        var entry = entries[sourceID] ?? Entry()
        entry.answers[questionID] = String(text.prefix(16_000))
        entry.updatedAt = Date()
        entries[sourceID] = entry
        prune()
    }

    public mutating func setHandled(_ handled: Bool, sourceID: String) {
        var entry = entries[sourceID] ?? Entry()
        entry.handled = handled
        entry.updatedAt = Date()
        entries[sourceID] = entry
        prune()
    }

    private mutating func prune() {
        if entries.count > 200 {
            let keep = Set(entries.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(200).map(\.key))
            entries = entries.filter { keep.contains($0.key) }
        }
    }

    public static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum QuickAnswerComposer {
    /// Include question wording and original numbering so partial answers cannot silently shift numbers.
    public static func reply(source: QuickQuestionSource, answers: [String: String]) -> String? {
        let answered = source.questions.enumerated().compactMap { index, question -> String? in
            guard let value = answers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            let number = question.number ?? String(index + 1)
            return "\(number). \(question.text)\nAnswer: \(value)"
        }
        guard !answered.isEmpty else { return nil }
        let location = source.kind == .markdown ? source.path : source.title
        var result = "Answers to your questions from \(location):\n\n" + answered.joined(separator: "\n\n")
        let missing = source.questions.count - answered.count
        if missing > 0 {
            result += "\n\n\(missing) question\(missing == 1 ? " is" : "s are") still unanswered; do not assume a choice for those."
        }
        return result
    }
}
