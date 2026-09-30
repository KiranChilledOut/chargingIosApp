import XCTest
@testable import NLLensCore

final class TierTests: XCTestCase {

    func testFreeIsTenImagesADayAndUnlimitedIsUncapped() {
        XCTAssertEqual(Tier.free.dailyImageLimit, 10)
        XCTAssertNil(Tier.unlimited.dailyImageLimit)
    }
}

final class AllowanceTests: XCTestCase {

    func testRemainingCountsDown() {
        let allowance = Allowance(tier: .free, usedToday: 4, limit: 10)
        XCTAssertEqual(allowance.remaining, 6)
        XCTAssertFalse(allowance.isExhausted)
    }

    func testExhaustedAtTheLimit() {
        XCTAssertTrue(Allowance(tier: .free, usedToday: 10, limit: 10).isExhausted)
        // Over the limit can happen if the server allowed something the client
        // had already counted differently; it must not read as "0 left, fine".
        XCTAssertTrue(Allowance(tier: .free, usedToday: 12, limit: 10).isExhausted)
        XCTAssertEqual(Allowance(tier: .free, usedToday: 12, limit: 10).remaining, 0)
    }

    func testPaidHasNoCeilingAndNeverNags() {
        let allowance = Allowance(tier: .unlimited, usedToday: 500, limit: nil)
        XCTAssertNil(allowance.remaining)
        XCTAssertFalse(allowance.isExhausted)
        XCTAssertNil(allowance.note)
    }

    /// A counter on screen from the first launch makes a generous allowance
    /// feel like a meter running.
    func testTheCounterStaysQuietUntilItMatters() {
        XCTAssertNil(Allowance(tier: .free, usedToday: 0, limit: 10).note)
        XCTAssertNil(Allowance(tier: .free, usedToday: 6, limit: 10).note)
        XCTAssertEqual(Allowance(tier: .free, usedToday: 7, limit: 10).note, "3 of 10 left today")
        XCTAssertEqual(
            Allowance(tier: .free, usedToday: 10, limit: 10).note,
            "Daily limit reached — 10 of 10 used"
        )
    }
}

final class UsageMeterTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    func testDayKeyFollowsTheDevicesOwnCalendar() {
        XCTAssertEqual(
            UsageMeter.dayKey(date("2026-03-14T09:00:00+01:00"), calendar: calendar),
            "2026-03-14"
        )
    }

    func testCountingAccumulatesWithinADay() {
        let now = date("2026-03-14T09:00:00+01:00")
        var record = UsageMeter.recording(1, in: nil, now: now, calendar: calendar)
        record = UsageMeter.recording(2, in: record, now: now, calendar: calendar)
        XCTAssertEqual(record, UsageRecord(day: "2026-03-14", count: 3))
    }

    /// Three screenshots stitched into one document is three images, because
    /// that is what someone was told they get.
    func testImagesAreCountedNotRuns() {
        let now = date("2026-03-14T09:00:00+01:00")
        let record = UsageMeter.recording(3, in: nil, now: now, calendar: calendar)
        XCTAssertEqual(record.count, 3)
    }

    func testTheTallyResetsAtLocalMidnight() {
        let record = UsageRecord(day: "2026-03-14", count: 10)
        let allowance = UsageMeter.allowance(
            record: record, tier: .free,
            now: date("2026-03-15T00:05:00+01:00"), calendar: calendar
        )
        XCTAssertEqual(allowance.usedToday, 0)
        XCTAssertFalse(allowance.isExhausted)
    }

    /// Setting the clock forward and back is the obvious way to refill a daily
    /// allowance. Refusing to rewind costs nothing for a correct clock.
    func testAClockMovedBackwardsDoesNotRefillTheAllowance() {
        let record = UsageRecord(day: "2026-03-20", count: 10)
        let rolled = UsageMeter.rolled(
            record, now: date("2026-03-14T09:00:00+01:00"), calendar: calendar
        )
        XCTAssertEqual(rolled, record, "the tally must not rewind with the clock")
    }

    func testPermissionRespectsWhatIsLeft() {
        let record = UsageRecord(day: "2026-03-14", count: 8)
        let now = date("2026-03-14T12:00:00+01:00")

        XCTAssertTrue(UsageMeter.permits(2, record: record, tier: .free, now: now, calendar: calendar))
        XCTAssertFalse(UsageMeter.permits(3, record: record, tier: .free, now: now, calendar: calendar))
    }

    /// A stitched document of four should be refused up front rather than
    /// half-processed and then cut off.
    func testABatchThatWouldOverrunIsRefusedWhole() {
        let record = UsageRecord(day: "2026-03-14", count: 7)
        let now = date("2026-03-14T12:00:00+01:00")
        XCTAssertFalse(UsageMeter.permits(4, record: record, tier: .free, now: now, calendar: calendar))
        XCTAssertTrue(UsageMeter.permits(3, record: record, tier: .free, now: now, calendar: calendar))
    }

    func testPaidIsNeverRefused() {
        let record = UsageRecord(day: "2026-03-14", count: 9_999)
        let now = date("2026-03-14T12:00:00+01:00")
        XCTAssertTrue(
            UsageMeter.permits(50, record: record, tier: .unlimited, now: now, calendar: calendar)
        )
    }

    func testNoRecordYetMeansNothingUsed() {
        let allowance = UsageMeter.allowance(
            record: nil, tier: .free,
            now: date("2026-03-14T09:00:00+01:00"), calendar: calendar
        )
        XCTAssertEqual(allowance.usedToday, 0)
        XCTAssertEqual(allowance.remaining, 10)
    }
}
