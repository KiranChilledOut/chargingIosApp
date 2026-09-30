import Foundation

/// What the person is entitled to.
public enum Tier: String, Sendable, Codable, Equatable, CaseIterable {
    case free
    case unlimited

    /// Images a day. Nil means no ceiling.
    public var dailyImageLimit: Int? {
        switch self {
        case .free: return 10
        case .unlimited: return nil
        }
    }

    public var title: String {
        switch self {
        case .free: return "Free"
        case .unlimited: return "Unlimited"
        }
    }
}

/// How much of today is left.
public struct Allowance: Sendable, Equatable {
    public let tier: Tier
    public let usedToday: Int
    public let limit: Int?

    public init(tier: Tier, usedToday: Int, limit: Int?) {
        self.tier = tier
        self.usedToday = usedToday
        self.limit = limit
    }

    public var remaining: Int? {
        guard let limit else { return nil }
        return max(0, limit - usedToday)
    }

    public var isExhausted: Bool {
        guard let remaining else { return false }
        return remaining == 0
    }

    /// Shown beside the capture button. Silent on the paid tier and while
    /// there is plenty left — a counter on screen from the first launch makes
    /// a generous allowance feel like a meter running.
    public var note: String? {
        guard let remaining, let limit else { return nil }
        if remaining == 0 { return "Daily limit reached — \(limit) of \(limit) used" }
        guard remaining <= 3 else { return nil }
        return "\(remaining) of \(limit) left today"
    }
}

/// One day's tally.
public struct UsageRecord: Sendable, Codable, Equatable {
    /// `yyyy-MM-dd` in the device's own calendar.
    public var day: String
    public var count: Int

    public init(day: String, count: Int) {
        self.day = day
        self.count = count
    }
}

/// Counts what has been translated today.
///
/// Deliberately **not** the enforcement point. Anything counted on the device
/// can be reset by deleting the app, and no amount of cleverness changes that.
/// The server that holds the API key is what actually refuses work; this exists
/// so the interface can say "3 left today" without asking, and so the paywall
/// appears before a request is made rather than after it is refused.
public struct UsageMeter: Sendable {

    /// Rolls the day over at local midnight, which is what "10 per day" means
    /// to a reader.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// The record rolled forward to `now`, if the day has changed.
    ///
    /// A day key that has gone *backwards* is left alone. Setting the clock
    /// forward and back is the obvious way to refill a daily allowance, and
    /// refusing to rewind costs nothing for someone whose clock is simply
    /// correct.
    public static func rolled(
        _ record: UsageRecord?, now: Date, calendar: Calendar = .current
    ) -> UsageRecord {
        let today = dayKey(now, calendar: calendar)
        guard let record else { return UsageRecord(day: today, count: 0) }

        if record.day == today { return record }
        if today < record.day { return record }
        return UsageRecord(day: today, count: 0)
    }

    /// Whether `images` more would fit.
    public static func permits(
        _ images: Int, record: UsageRecord?, tier: Tier,
        now: Date, calendar: Calendar = .current
    ) -> Bool {
        guard let limit = tier.dailyImageLimit else { return true }
        let current = rolled(record, now: now, calendar: calendar)
        return current.count + images <= limit
    }

    /// Records `images` and returns the updated tally.
    ///
    /// Counts images rather than runs, because that is what someone was told
    /// they get. Three screenshots stitched into one document is three.
    public static func recording(
        _ images: Int, in record: UsageRecord?,
        now: Date, calendar: Calendar = .current
    ) -> UsageRecord {
        var current = rolled(record, now: now, calendar: calendar)
        current.count += max(0, images)
        return current
    }

    public static func allowance(
        record: UsageRecord?, tier: Tier, now: Date, calendar: Calendar = .current
    ) -> Allowance {
        let current = rolled(record, now: now, calendar: calendar)
        return Allowance(tier: tier, usedToday: current.count, limit: tier.dailyImageLimit)
    }
}
