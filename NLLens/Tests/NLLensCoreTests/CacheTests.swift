import XCTest
@testable import NLLensCore

final class CacheTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = temporaryCacheURL()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testStoreFlushAndReloadRoundTrip() async throws {
        let cache = TranslationCache(fileURL: url)
        try await cache.load()
        await cache.store(nl: "Instellingen", en: "Settings")
        await cache.store(nl: "Openen", en: "Open")
        _ = try await cache.flush()

        let reloaded = TranslationCache(fileURL: url)
        try await reloaded.load()

        let hit = await reloaded.lookup("Instellingen")
        XCTAssertEqual(hit?.en, "Settings")
        let count = await reloaded.count
        XCTAssertEqual(count, 2)
    }

    func testLookupIsCaseAndWhitespaceInsensitive() async throws {
        let cache = TranslationCache(fileURL: url)
        try await cache.load()
        await cache.store(nl: "Mijn Gegevens", en: "My details")

        let variants = ["mijn gegevens", "  Mijn   Gegevens  ", "MIJN GEGEVENS"]
        for variant in variants {
            let hit = await cache.lookup(variant)
            XCTAssertEqual(hit?.en, "My details", "failed for \(variant)")
        }
    }

    func testLaterEntryWins() async throws {
        let cache = TranslationCache(fileURL: url)
        try await cache.load()
        await cache.store(nl: "Afsluiten", en: "Close")
        _ = try await cache.flush()
        await cache.store(nl: "Afsluiten", en: "Exit")
        _ = try await cache.flush()

        let reloaded = TranslationCache(fileURL: url)
        try await reloaded.load()
        let hit = await reloaded.lookup("Afsluiten")
        XCTAssertEqual(hit?.en, "Exit")
    }

    func testPinnedCorrectionSurvivesLaterModelResult() async throws {
        let cache = TranslationCache(fileURL: url)
        try await cache.load()
        await cache.pin(nl: "Storting", en: "Deposit")
        _ = try await cache.flush()

        // A later model run disagrees; the hand correction must hold.
        await cache.store(nl: "Storting", en: "Dumping")
        _ = try await cache.flush()
        let live = await cache.lookup("Storting")
        XCTAssertEqual(live?.en, "Deposit")

        let reloaded = TranslationCache(fileURL: url)
        try await reloaded.load()
        let persisted = await reloaded.lookup("Storting")
        XCTAssertEqual(persisted?.en, "Deposit", "pin must survive reload too")
    }

    func testCorruptLineIsSkippedNotFatal() async throws {
        let cache = TranslationCache(fileURL: url)
        try await cache.load()
        await cache.store(nl: "Openen", en: "Open")
        _ = try await cache.flush()

        // Simulate a process killed mid-append.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"k":"broken","nl":"x"#.utf8))
        try handle.close()

        let reloaded = TranslationCache(fileURL: url)
        try await reloaded.load()
        let hit = await reloaded.lookup("Openen")
        XCTAssertEqual(hit?.en, "Open", "good entries must survive a torn tail")
    }

    func testCompactionShrinksTheLog() async throws {
        let cache = TranslationCache(fileURL: url)
        try await cache.load()

        // Rewrite the same few keys many times to build up dead lines.
        for round in 0..<80 {
            await cache.store(nl: "Knop", en: "Button \(round)")
            await cache.store(nl: "Menu", en: "Menu \(round)")
            _ = try await cache.flush()
        }

        let lines = await cache.storedLineCount
        let entries = await cache.count
        XCTAssertEqual(entries, 2)
        XCTAssertLessThan(lines, 80, "log should have been compacted, got \(lines)")

        let reloaded = TranslationCache(fileURL: url)
        try await reloaded.load()
        let hit = await reloaded.lookup("Knop")
        XCTAssertEqual(hit?.en, "Button 79", "compaction must keep the newest value")
    }

    func testPartitionSplitsHitsFromMisses() async throws {
        let cache = TranslationCache(fileURL: url)
        try await cache.load()
        await cache.store(nl: "Openen", en: "Open")

        let blocks = [
            TextBlock(id: 0, text: "Openen", box: BoundingBox(x: 0, y: 0, width: 1, height: 1)),
            TextBlock(id: 1, text: "Annuleren", box: BoundingBox(x: 0, y: 0, width: 1, height: 1)),
        ]
        let result = await cache.partition(blocks: blocks)
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertEqual(result.misses.map(\.text), ["Annuleren"])
    }
}
