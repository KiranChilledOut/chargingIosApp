import SwiftUI
import NLLensCore

/// One source for spacing, shape, colour and type.
///
/// Tokens rather than ad-hoc values, because "modern and elegant" in practice
/// is mostly consistency: the same rhythm everywhere, a small palette used
/// with restraint, and type that respects the reader's chosen size. A view
/// that reaches for a literal `16` is a view that will drift.
enum Theme {

    /// A 4-point rhythm. Everything spatial is a multiple of it.
    enum Space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Comfortable page margin.
        static let page: CGFloat = 20
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 18
        /// Pills and chips.
        static let pill: CGFloat = 999
    }

    enum Palette {
        /// Everything tinted uses this one colour, so emphasis stays scarce
        /// enough to mean something.
        static let accent = Color.accentColor

        static let surface = Color(.secondarySystemBackground)
        static let page = Color(.systemBackground)
        static let hairline = Color(.separator)

        static func risk(_ level: RiskAssessment.Level) -> Color {
            switch level {
            case .fine: return .green
            case .caution: return .orange
            case .danger: return .red
            }
        }
    }

    enum Typeface {
        /// Screen titles.
        static let title = Font.title2.weight(.semibold)
        /// Section headers.
        static let section = Font.subheadline.weight(.semibold)
        /// Body copy meant to be read at length.
        static let reading = Font.body
        /// Supporting detail.
        static let detail = Font.footnote
        /// The quietest text that still has to be legible.
        static let caption = Font.caption
    }

    /// Duration used for anything that moves, so transitions feel like one
    /// system rather than several.
    enum Motion {
        static let quick = Animation.easeInOut(duration: 0.18)
        static let settle = Animation.spring(response: 0.34, dampingFraction: 0.86)
    }
}

// MARK: - Building blocks

extension View {

    /// A grouped surface: the default container for anything that is not
    /// plain running text.
    func cardSurface(
        padding: CGFloat = Theme.Space.l,
        radius: CGFloat = Theme.Radius.large
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: radius))
    }

    /// A compact pill, for status and filters.
    func pill(tint: Color = Theme.Palette.accent) -> some View {
        self
            .font(Theme.Typeface.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.xs + 2)
            .background(tint.opacity(0.14), in: Capsule())
    }

    /// Floating controls over content: readable on a screenshot of anything.
    func floatingControl() -> some View {
        self
            .padding(Theme.Space.s + 2)
            .background(.ultraThinMaterial, in: Circle())
    }
}

/// A labelled block with consistent spacing above and below.
///
/// Named `LabeledSection`, not `Section`: SwiftUI already has a `Section` used
/// throughout `Form` and `List`, and a same-named type in this module would
/// shadow it everywhere.
struct LabeledSection<Content: View>: View {
    let title: String
    var systemImage: String?
    var tint: Color = Theme.Palette.accent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .font(Theme.Typeface.section)
                    .foregroundStyle(tint)
            } else {
                Text(title)
                    .font(Theme.Typeface.section)
                    .foregroundStyle(tint)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
