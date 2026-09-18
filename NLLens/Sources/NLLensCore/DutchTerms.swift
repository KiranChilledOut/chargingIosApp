import Foundation

/// A Dutch term whose English translation does not tell you what it is.
public struct DutchTerm: Sendable, Equatable, Identifiable {
    public enum Category: String, Sendable, CaseIterable {
        case tax, identity, health, housing, banking, work, benefits
    }

    /// The Dutch term as written.
    public let term: String
    /// What a translator gives you. Usually useless on its own.
    public let literal: String
    /// What it actually is in the Dutch system.
    public let meaning: String
    public let category: Category
    /// Other spellings and abbreviations that mean the same thing.
    public let aliases: [String]

    public var id: String { term }

    public init(
        term: String,
        literal: String,
        meaning: String,
        category: Category,
        aliases: [String] = []
    ) {
        self.term = term
        self.literal = literal
        self.meaning = meaning
        self.category = category
        self.aliases = aliases
    }
}

/// The terms where translation and understanding come apart.
///
/// This is the difference between an app that reads Dutch and one that is
/// useful in the Netherlands. "Eigen risico" translates faithfully to "own
/// risk" and leaves the reader no wiser; what they need is that it is the
/// fixed yearly amount of medical costs they pay before insurance starts.
/// No general translator will ever supply the second thing, because it is not
/// translation — it is knowledge of one country's systems.
///
/// Amounts and rates are deliberately absent: they change yearly, and a
/// confidently stale number is worse than none.
public enum DutchTermIndex {

    public static let all: [DutchTerm] = [
        // MARK: Identity
        .init(term: "BSN", literal: "citizen service number",
              meaning: "Your Dutch national identity number, 9 digits. Needed for work, banking, healthcare and tax. Printed on your ID card and in your municipality registration.",
              category: .identity, aliases: ["burgerservicenummer", "sofinummer"]),
        .init(term: "DigiD", literal: "DigiD",
              meaning: "The national login used for government and healthcare websites. A real DigiD screen never asks for your password inside another company's app or by email.",
              category: .identity),
        .init(term: "gemeente", literal: "municipality",
              meaning: "Your local council. Handles address registration, ID documents and many local taxes. Most official processes start here.",
              category: .identity),
        .init(term: "inschrijven", literal: "to register",
              meaning: "Registering your address with the municipality. Legally required, and a precondition for a BSN, a bank account and most else.",
              category: .identity),

        // MARK: Tax
        .init(term: "Belastingdienst", literal: "tax service",
              meaning: "The Dutch tax authority. Also administers benefits (toeslagen), so letters from them may be about either.",
              category: .tax),
        .init(term: "aangifte", literal: "declaration",
              meaning: "Your tax return. Usually filed between March and May for the previous calendar year.",
              category: .tax, aliases: ["belastingaangifte"]),
        .init(term: "voorlopige aanslag", literal: "provisional assessment",
              meaning: "An estimated tax bill or refund, based on expected figures rather than final ones. You can ask for it to be corrected during the year.",
              category: .tax),
        .init(term: "definitieve aanslag", literal: "definitive assessment",
              meaning: "The final tax decision after your return is processed. This is the one that settles what you owe or are owed.",
              category: .tax),
        .init(term: "loonheffingskorting", literal: "payroll tax credit",
              meaning: "A tax credit applied through your salary. Apply it at only ONE employer at a time — applying it at two is a common cause of owing tax back later.",
              category: .tax),
        .init(term: "fiscaal partner", literal: "fiscal partner",
              meaning: "A partner you are assessed jointly with for tax. Affects deductions and benefit entitlements. Not the same as simply living together.",
              category: .tax, aliases: ["fiscale partner", "fiscaal partnerschap"]),
        .init(term: "aftrek", literal: "deduction",
              meaning: "An amount subtracted from taxable income, lowering the tax due.",
              category: .tax, aliases: ["aftrekpost", "aftrekbaar"]),
        .init(term: "hypotheekrenteaftrek", literal: "mortgage interest deduction",
              meaning: "Tax relief on mortgage interest, for homeowners only. Does not apply if you rent.",
              category: .tax, aliases: ["hypotheekrente"]),
        .init(term: "bijtelling", literal: "addition",
              meaning: "Taxable benefit added to your income for private use of a company car.",
              category: .tax),
        .init(term: "jaaropgave", literal: "annual statement",
              meaning: "The yearly summary from your employer of income and tax paid. The figures you need for your tax return.",
              category: .tax),

        // MARK: Benefits
        .init(term: "toeslag", literal: "allowance",
              meaning: "A means-tested benefit paid monthly in advance and corrected later. If your income rises you may have to pay some back.",
              category: .benefits, aliases: ["toeslagen"]),
        .init(term: "zorgtoeslag", literal: "care allowance",
              meaning: "A means-tested contribution towards health insurance premiums for lower incomes.",
              category: .benefits),
        .init(term: "huurtoeslag", literal: "rent allowance",
              meaning: "A means-tested contribution towards rent, subject to limits on rent level and income.",
              category: .benefits),
        .init(term: "terugvordering", literal: "reclamation",
              meaning: "A demand to repay benefit you received but were not entitled to, usually after an income correction.",
              category: .benefits),

        // MARK: Health
        .init(term: "zorgverzekering", literal: "care insurance",
              meaning: "Basic health insurance. Legally compulsory for residents, bought from a private insurer.",
              category: .health, aliases: ["basisverzekering"]),
        .init(term: "eigen risico", literal: "own risk",
              meaning: "Your yearly insurance deductible: the fixed amount of medical costs you pay yourself before basic insurance starts paying. Set nationally each year.",
              category: .health),
        .init(term: "eigen bijdrage", literal: "own contribution",
              meaning: "A co-payment you owe on top of what insurance covers. Separate from the eigen risico.",
              category: .health),
        .init(term: "huisarts", literal: "house doctor",
              meaning: "Your GP, and the gateway to almost all other care. Specialists normally require a referral from them.",
              category: .health),
        .init(term: "verwijzing", literal: "referral",
              meaning: "A GP referral to a specialist. Without one, insurance may refuse the specialist's bill.",
              category: .health, aliases: ["verwijsbrief"]),
        .init(term: "aanvullende verzekering", literal: "supplementary insurance",
              meaning: "Optional extra cover on top of the basic policy, for things like dental or physiotherapy.",
              category: .health),

        // MARK: Housing
        .init(term: "WOZ-waarde", literal: "WOZ value",
              meaning: "The municipality's official valuation of a property. Several taxes are calculated from it, and it can be formally disputed.",
              category: .housing, aliases: ["WOZ", "WOZ waarde"]),
        .init(term: "servicekosten", literal: "service costs",
              meaning: "Charges on top of rent for shared services. Must be itemised, and you are entitled to an annual breakdown.",
              category: .housing),
        .init(term: "borg", literal: "security",
              meaning: "A rental deposit, refundable at the end of the tenancy less any justified deductions.",
              category: .housing, aliases: ["waarborgsom"]),
        .init(term: "huurcommissie", literal: "rent committee",
              meaning: "The official body that rules on rent and maintenance disputes. Cheap to approach and binding.",
              category: .housing),
        .init(term: "kale huur", literal: "bare rent",
              meaning: "Rent excluding service charges and utilities. Benefit calculations use this figure, not the total you pay.",
              category: .housing),
        .init(term: "opzegtermijn", literal: "notice period",
              meaning: "How much notice you must give to end a contract — tenancy, employment or subscription.",
              category: .housing),

        // MARK: Banking
        .init(term: "automatische incasso", literal: "automatic collection",
              meaning: "A direct debit. You can reverse one through your bank, usually within eight weeks and without giving a reason.",
              category: .banking, aliases: ["incasso"]),
        .init(term: "machtiging", literal: "authorisation",
              meaning: "Permission for an organisation to take money from your account by direct debit.",
              category: .banking),
        .init(term: "iDEAL", literal: "iDEAL",
              meaning: "The standard Dutch online payment method, going through your own bank's app.",
              category: .banking),
        .init(term: "afschrijving", literal: "write-off",
              meaning: "Money debited from your account.",
              category: .banking),
        .init(term: "bijschrijving", literal: "write-on",
              meaning: "Money credited to your account.",
              category: .banking),
        .init(term: "rekeningnummer", literal: "account number",
              meaning: "Your bank account number, given as an IBAN starting with NL.",
              category: .banking),

        // MARK: Work
        .init(term: "loonstrook", literal: "wage slip",
              meaning: "Your payslip, showing gross pay, deductions and net pay.",
              category: .work, aliases: ["salarisstrook"]),
        .init(term: "vakantiegeld", literal: "holiday money",
              meaning: "A statutory holiday allowance, typically around 8% of annual salary, usually paid in May.",
              category: .work),
        .init(term: "CAO", literal: "collective labour agreement",
              meaning: "A sector-wide agreement setting pay and conditions. It can override what your individual contract says.",
              category: .work, aliases: ["collectieve arbeidsovereenkomst"]),
        .init(term: "proeftijd", literal: "trial time",
              meaning: "A probation period during which either side can end the contract immediately. Its maximum length is legally limited.",
              category: .work),
        .init(term: "WW", literal: "WW",
              meaning: "Unemployment benefit, based on your work history.",
              category: .work, aliases: ["werkloosheidsuitkering"]),
        .init(term: "transitievergoeding", literal: "transition compensation",
              meaning: "Statutory severance pay owed when an employer ends your contract.",
              category: .work),
    ]

    /// Terms appearing in the given text, most specific first.
    ///
    /// Matched on word runs rather than substrings, because Dutch compounds
    /// would otherwise produce nonsense — "borg" sits inside "borgstelling"
    /// and "Borgerhout", and flagging either would be worse than saying
    /// nothing.
    public static func matches(in text: String, limit: Int = 12) -> [DutchTerm] {
        let haystack = tokens(of: text)
        guard !haystack.isEmpty else { return [] }

        var found: [(term: DutchTerm, length: Int)] = []
        for entry in all {
            let candidates = [entry.term] + entry.aliases
            let best = candidates
                .map { tokens(of: $0) }
                .filter { !$0.isEmpty && contains(haystack, $0) }
                .map(\.count)
                .max()
            if let best {
                found.append((entry, best))
            }
        }

        // Longer matches first: a screen mentioning "voorlopige aanslag" is
        // better served by that than by "aanslag" alone.
        return found
            .sorted { $0.length != $1.length ? $0.length > $1.length : $0.term.term < $1.term.term }
            .prefix(limit)
            .map(\.term)
    }

    /// A compact block explaining the terms on this screen, for the model's
    /// grounding. Empty when nothing matched, so it costs nothing on screens
    /// that need no help.
    public static func grounding(for text: String, limit: Int = 12) -> String {
        let terms = matches(in: text, limit: limit)
        guard !terms.isEmpty else { return "" }

        let lines = terms.map { "- \($0.term) (literally \"\($0.literal)\"): \($0.meaning)" }
        return """
        Dutch terms on this screen, and what they mean in the Dutch system. \
        Prefer these explanations over a literal translation:
        \(lines.joined(separator: "\n"))
        """
    }

    public static func term(named name: String) -> DutchTerm? {
        let wanted = tokens(of: name)
        return all.first { entry in
            ([entry.term] + entry.aliases).contains { tokens(of: $0) == wanted }
        }
    }

    // MARK: - Matching

    /// Lowercased alphanumeric runs. Splitting on everything else means
    /// "WOZ-waarde" and "WOZ waarde" tokenize identically.
    static func tokens(of text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Whether `needle` appears as a contiguous run inside `haystack`.
    static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<start + needle.count]) == needle { return true }
        }
        return false
    }
}
