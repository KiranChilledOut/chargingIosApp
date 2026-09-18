import XCTest
@testable import NLLensCore

final class ScreenConversationTests: XCTestCase {

    private func conversation(turns: Int = 0, size: Int = 10) -> ScreenConversation {
        var c = ScreenConversation(
            screenText: "Your provisional assessment for 2025",
            termGrounding: "- voorlopige aanslag: an estimated tax bill",
            visualReading: "A Belastingdienst tax form"
        )
        for index in 0..<turns {
            c.append(role: index.isMultiple(of: 2) ? .user : .assistant,
                     text: String(repeating: "x", count: size) + "\(index)")
        }
        return c
    }

    func testAppendIgnoresBlankText() {
        var c = conversation()
        c.append(role: .user, text: "   \n ")
        XCTAssertTrue(c.isEmpty)
    }

    func testAppendTrimsWhitespace() {
        var c = conversation()
        c.append(role: .user, text: "  which box?  ")
        XCTAssertEqual(c.messages.first?.text, "which box?")
    }

    func testScreenLivesInTheSystemMessageNotTheTurns() {
        // The whole cost model depends on this: the screen is established
        // once, and turns stay cheap text.
        var c = conversation()
        c.append(role: .user, text: "which option?")

        let messages = c.requestMessages(instructions: "INSTRUCTIONS")
        guard case .text(let system) = messages[0].content[0] else {
            return XCTFail("first message should be the system prompt")
        }
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertTrue(system.contains("INSTRUCTIONS"))
        XCTAssertTrue(system.contains("provisional assessment"))
        XCTAssertTrue(system.contains("voorlopige aanslag"))
        XCTAssertTrue(system.contains("Belastingdienst tax form"))

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1].role, .user)
    }

    func testRolesSurviveIntoTheRequest() {
        var c = conversation()
        c.append(role: .user, text: "a")
        c.append(role: .assistant, text: "b")
        c.append(role: .user, text: "c")

        let roles = c.requestMessages(instructions: "x").map(\.role)
        XCTAssertEqual(roles, [.system, .user, .assistant, .user])
    }

    func testEmptyGroundingIsOmittedRatherThanSentBlank() {
        let bare = ScreenConversation()
        let system = bare.systemMessage(instructions: "ONLY THIS")
        XCTAssertEqual(system, "ONLY THIS")
    }

    func testHistoryIsTrimmedFromTheOldestEnd() {
        let c = conversation(turns: 20, size: 100)
        let kept = c.recentHistory(budget: 450)

        XCTAssertLessThan(kept.count, c.messages.count)
        XCTAssertEqual(kept.last?.text, c.messages.last?.text, "newest must survive")
    }

    func testNewestMessageIsKeptEvenWhenItAloneExceedsBudget() {
        // Dropping the question being asked would leave nothing to answer.
        var c = conversation()
        c.append(role: .user, text: String(repeating: "y", count: 5000))
        let kept = c.recentHistory(budget: 100)
        XCTAssertEqual(kept.count, 1)
    }

    func testNothingIsTrimmedWhenItAllFits() {
        let c = conversation(turns: 4, size: 10)
        XCTAssertEqual(c.recentHistory(budget: 10_000).count, 4)
        XCTAssertFalse(c.isTrimmed(budget: 10_000))
    }

    func testIsTrimmedReportsLoss() {
        let c = conversation(turns: 20, size: 100)
        XCTAssertTrue(c.isTrimmed(budget: 300))
    }

    func testHistoryStaysInChronologicalOrder() {
        let c = conversation(turns: 6, size: 5)
        let kept = c.recentHistory(budget: 10_000)
        XCTAssertEqual(kept.map(\.text), c.messages.map(\.text))
    }

    func testRemoveLastDropsAnUnansweredQuestion() {
        var c = conversation(turns: 2, size: 5)
        c.append(role: .user, text: "unanswered")
        c.removeLast()
        XCTAssertEqual(c.messages.count, 2)
    }

    func testRemoveLastOnEmptyIsSafe() {
        var c = conversation()
        c.removeLast()
        XCTAssertTrue(c.isEmpty)
    }

    func testRoundTripsThroughCoding() throws {
        var c = conversation(turns: 3, size: 8)
        c.append(role: .user, text: "keep me")

        let data = try JSONEncoder().encode(c)
        let restored = try JSONDecoder().decode(ScreenConversation.self, from: data)
        XCTAssertEqual(restored.messages.map(\.text), c.messages.map(\.text))
        XCTAssertEqual(restored.screenText, c.screenText)
    }
}
