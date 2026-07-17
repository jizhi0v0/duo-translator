import XCTest
@testable import DuoTranslator

@MainActor
final class StatsStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-\(UUID().uuidString).json")
    }

    private func record(_ status: RecordStatus = .success, total: Int? = 15) -> TranslationRecord {
        TranslationRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            engineKind: "openAICompat", engineName: "OpenAI",
            source: "en", target: "zh-Hans",
            inputChars: 42, outputChars: 30,
            promptTokens: 10, completionTokens: 5, totalTokens: total,
            durationSeconds: 1.6, status: status
        )
    }

    func testRoundTripPersistsAcrossInstances() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = StatsStore(fileURL: url)
        store.add(record())
        store.add(record(.failed))
        XCTAssertEqual(store.records.count, 2)

        let reloaded = StatsStore(fileURL: url)
        XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.records.first?.engineName, "OpenAI")
        XCTAssertEqual(reloaded.records.last?.status, .failed)
    }

    func testStoresMetadataOnlyNoTextFields() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StatsStore(fileURL: url)
        store.add(record())

        let raw = try String(contentsOf: url, encoding: .utf8)
        // Only lengths/metadata are persisted; there is no field carrying source
        // or translated text.
        XCTAssertTrue(raw.contains("inputChars"))
        XCTAssertFalse(raw.contains("\"text\""))
        XCTAssertFalse(raw.contains("inputText"))
    }

    func testClearEmptiesStore() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StatsStore(fileURL: url)
        store.add(record())
        store.clear()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(StatsStore(fileURL: url).records.isEmpty)
    }
}
