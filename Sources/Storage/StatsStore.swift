import Foundation
import Combine

enum RecordStatus: String, Codable, Sendable {
    case success
    case failed
    case cancelled
}

/// Metadata-only record of one engine translation. Deliberately stores no input
/// or output text — only lengths — so the history is safe to keep and export.
struct TranslationRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let engineKind: String
    let engineName: String
    let source: String?
    let target: String
    let inputChars: Int
    let outputChars: Int
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let durationSeconds: Double
    let status: RecordStatus
    /// Request start → first token, for latency trends per engine.
    var ttftSeconds: Double?
    /// Cost at the prices configured when the run happened. Stored rather than
    /// derived so later price edits don't rewrite history.
    var cost: Double?
    /// Prompt tokens served from cache, for a cache-effectiveness view.
    var cachedPromptTokens: Int?
}

/// Persists translation metadata for the stats window. Backed by a JSON file in
/// Application Support, capped to the most recent `maxRecords` entries.
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    @Published private(set) var records: [TranslationRecord] = []

    private let maxRecords = 5000
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    func add(_ record: TranslationRecord) {
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        save()
    }

    func clear() {
        records = []
        save()
    }

    // MARK: - Persistence

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("DuoTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stats.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([TranslationRecord].self, from: data) {
            records = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
