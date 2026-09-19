import XCTest
@testable import NLLensCore

final class MemoryFactTests: XCTestCase {

    func testKeysAreNormalizedSoTheSameFactSupersedesItself() {
        XCTAssertEqual(MemoryFact.normalizeKey("Energy Tariff"), "energy-tariff")
        XCTAssertEqual(MemoryFact.normalizeKey("energy_tariff"), "energy-tariff")
        XCTAssertEqual(MemoryFact.normalizeKey("  ENERGY  TARIFF  "), "energy-tariff")
        XCTAssertEqual(MemoryFact.normalizeKey("health-insurance"), "health-insurance")
    }

    /// Facts are extracted from text that has already been redacted, so an
    /// IBAN arrives as "[[R1]]". Storing that would have the model quoting a
    /// token back as though it were a value.
    func testRedactionPlaceholdersAreNeverStored() {
        let fact = MemoryFact(key: "bank", label: "Account", value: "IBAN [[R1]]")
        XCTAssertFalse(fact.isStorable)
    }

    func testAModelSayingItKnowsNothingIsNotAFact() {
        for empty in ["unknown", "None", "n/a", "not stated", "null", ""] {
            XCTAssertFalse(
                MemoryFact(key: "housing", label: "Housing", value: empty).isStorable,
                "\(empty) should not be stored"
            )
        }
    }

    func testAnOverlongValueIsRejected() {
        let essay = String(repeating: "x", count: 300)
        XCTAssertFalse(MemoryFact(key: "k", label: "l", value: essay).isStorable)
    }

    func testLineReadsAsAPromptLine() {
        let fact = MemoryFact(key: "energy-tariff", label: "Electricity", value: "€0.26/kWh")
        XCTAssertEqual(fact.line, "Electricity: €0.26/kWh")
    }
}

final class MemoryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(limit: Int = 120) -> MemoryStore {
        MemoryStore(fileURL: directory.appendingPathComponent("memory.jsonl"), limit: limit)
    }

    func testFactsSurviveAReload() async throws {
        let first = store()
        try await first.record([
            MemoryFact(key: "energy-tariff", label: "Electricity", value: "€0.26/kWh"),
            MemoryFact(key: "city", label: "City", value: "Amsterdam"),
        ])

        let second = store()
        try await second.load()
        let count = await second.count
        XCTAssertEqual(count, 2)
        let values = await second.all.map(\.value).sorted()
        XCTAssertEqual(values, ["Amsterdam", "€0.26/kWh"])
    }

    /// The point of keying: a tariff learned twice is one fact with a new
    /// value, not two the model has to choose between.
    func testANewValueSupersedesTheOldOne() async throws {
        let memory = store()
        try await memory.record([
            MemoryFact(key: "energy-tariff", label: "Electricity", value: "€0.26/kWh")
        ])
        try await memory.record([
            MemoryFact(key: "energy-tariff", label: "Electricity", value: "€0.24/kWh")
        ])

        let all = await memory.all
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.value, "€0.24/kWh")

        // And it survives, rather than the superseded line winning on reload.
        let reloaded = store()
        try await reloaded.load()
        let after = await reloaded.all
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.value, "€0.24/kWh")
    }

    func testRelearningTheSameValueRecordsNothing() async throws {
        let memory = store()
        let fact = MemoryFact(key: "city", label: "City", value: "Utrecht")
        let first = try await memory.record([fact])
        let second = try await memory.record([fact])

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty, "nothing new was learned")
    }

    func testUnstorableFactsAreDroppedAtTheDoor() async throws {
        let memory = store()
        let kept = try await memory.record([
            MemoryFact(key: "bank", label: "Account", value: "[[R1]]"),
            MemoryFact(key: "city", label: "City", value: "Rotterdam"),
        ])
        XCTAssertEqual(kept.map(\.key), ["city"])
    }

    func testTheOldestGoWhenTheStoreIsFull() async throws {
        let memory = store(limit: 3)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<5 {
            try await memory.record([
                MemoryFact(
                    key: "fact-\(index)", label: "L", value: "v\(index)",
                    recordedAt: base.addingTimeInterval(Double(index) * 60)
                )
            ])
        }
        let all = await memory.all
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.key).sorted(), ["fact-2", "fact-3", "fact-4"])
    }

    func testForgettingRemovesItFromDiskToo() async throws {
        let memory = store()
        try await memory.record([
            MemoryFact(key: "city", label: "City", value: "Delft"),
            MemoryFact(key: "housing", label: "Housing", value: "renting"),
        ])
        try await memory.forget(key: "City")

        let reloaded = store()
        try await reloaded.load()
        let keys = await reloaded.all.map(\.key)
        XCTAssertEqual(keys, ["housing"], "forgetting must outlive the process")
    }

    // MARK: - Recall

    func testRecallPrefersFactsThatShareWordsWithTheQuestion() async throws {
        let memory = store()
        try await memory.record([
            MemoryFact(key: "energy-tariff", label: "Electricity tariff", value: "€0.26 per kWh"),
            MemoryFact(key: "health-insurance", label: "Health insurer", value: "CZ, €385 excess"),
            MemoryFact(key: "city", label: "City", value: "Eindhoven"),
        ])

        let picked = await memory.relevant(to: "is my electricity tariff competitive?", limit: 1)
        XCTAssertEqual(picked.map(\.key), ["energy-tariff"])
    }

    func testGroundingIsEmptyWithNothingRemembered() async throws {
        let grounding = await store().grounding(for: "anything")
        XCTAssertTrue(grounding.isEmpty, "an empty block would be prompt noise")
    }

    func testGroundingTellsTheModelToBuildOnItRatherThanAskAgain() async throws {
        let memory = store()
        try await memory.record([
            MemoryFact(key: "housing", label: "Housing", value: "rents, no fiscal partner")
        ])

        let grounding = await memory.grounding(for: "which box do I tick?")
        XCTAssertTrue(grounding.contains("rents, no fiscal partner"))
        XCTAssertTrue(grounding.lowercased().contains("rather than asking again"))
        XCTAssertTrue(
            grounding.lowercased().contains("correct"),
            "they must be able to correct a fact that has changed"
        )
    }

    func testARecalledFactCapIsRespected() async throws {
        let memory = store()
        try await memory.record((0..<20).map {
            MemoryFact(key: "k\($0)", label: "L\($0)", value: "v\($0)")
        })
        let picked = await memory.relevant(to: "unrelated question", limit: 5)
        XCTAssertEqual(picked.count, 5, "a prompt carrying twenty facts buries the two that matter")
    }
}

/// End to end: what is remembered has to actually reach the prompt, and what
/// an exchange reveals has to actually get written down. Either half missing
/// and the chat still restarts from nothing every time.
final class MemoryInThePipelineTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> MemoryStore {
        MemoryStore(fileURL: directory.appendingPathComponent("memory.jsonl"))
    }

    private func pipeline(
        _ transport: MockTransport,
        memory: MemoryStore?,
        settings: AppSettings = .default
    ) -> TranslationPipeline {
        TranslationPipeline(
            client: .test(transport: transport),
            cache: nil,
            settings: settings,
            textModel: "configured/model",
            search: nil,
            memory: memory
        )
    }

    private var conversation: ScreenConversation {
        var c = ScreenConversation(screenText: "Energy contract, electricity per kWh")
        c.append(role: .user, text: "is this a good tariff?")
        return c
    }

    func testRememberedFactsReachTheAnswerPrompt() async throws {
        let memory = store()
        try await memory.record([
            MemoryFact(key: "energy-tariff", label: "Electricity tariff", value: "€0.25970 per kWh")
        ])

        let transport = MockTransport(stubs: [.completion("ok")])
        _ = try await pipeline(transport, memory: memory).answer(in: conversation)

        let prompt = transport.recordedBodies().first ?? ""
        XCTAssertTrue(prompt.contains("0.25970"), "the remembered tariff must be in the prompt")
    }

    /// Driven directly rather than through `answer`, because learning is
    /// detached: awaiting it would park a composed reply behind a call the
    /// user never asked for, so `answer` starts it and returns.
    func testWhatTheExchangeRevealsIsWrittenDown() async throws {
        let memory = store()
        let transport = MockTransport(stubs: [
            .completion(
                #"{"facts":[{"key":"energy-provider","label":"Energy provider","value":"Budget Thuis"}]}"#
            )
        ])

        await pipeline(transport, memory: memory).learn(
            from: conversation, question: "is this a good tariff?",
            answer: "You are on a fixed tariff.", model: "m"
        )

        let all = await memory.all
        XCTAssertEqual(all.map(\.key), ["energy-provider"])
        XCTAssertEqual(all.first?.value, "Budget Thuis")
    }

    func testAnswersDoNotWaitForLearning() async throws {
        let memory = store()
        // One stub only: the answer. If learning were awaited, the second call
        // would exhaust the stubs and throw.
        let transport = MockTransport(stubs: [.completion("here is your answer")])

        let answer = try await pipeline(transport, memory: memory).answer(in: conversation)
        XCTAssertEqual(answer.text, "here is your answer")
    }

    func testAFailureToRememberIsSwallowed() async throws {
        let memory = store()
        let transport = MockTransport(stubs: [.json("upstream exploded", status: 500)])

        await pipeline(transport, memory: memory).learn(
            from: conversation, question: "q", answer: "a", model: "m"
        )

        let count = await memory.count
        XCTAssertEqual(count, 0, "nothing recorded, and nothing thrown")
    }

    func testMemoryCanBeTurnedOff() async throws {
        var settings = AppSettings.default
        settings.memoryEnabled = false

        let memory = store()
        let transport = MockTransport(stubs: [])
        await pipeline(transport, memory: memory, settings: settings).learn(
            from: conversation, question: "q", answer: "a", model: "m"
        )

        XCTAssertEqual(transport.requestCount, 0, "no learning call when memory is off")
        let count = await memory.count
        XCTAssertEqual(count, 0)
    }
}
