import SwiftUI
import NLLensCore

/// The translated screen as text rather than as a picture of text.
///
/// The overlay is the right answer for a screen of controls, where knowing
/// which label belongs to which button is the whole point. It is the wrong
/// answer for a screen of prose: you end up pinching around an image at
/// whatever size the original font happened to be, with no reflow, no Dynamic
/// Type, no selection, and no way to keep reading past the bottom of the
/// capture. This mode gives all of those back.
struct ReadingModeView: View {

    let blocks: [TranslatedBlock]
    let showSource: Bool
    var onCorrect: (TranslatedBlock) -> Void

    private var roles: [Int: TextRole] {
        TypographyHints.roles(for: blocks)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    row(for: block, role: roles[block.id] ?? .body)
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, Theme.Space.l)
            .textSelection(.enabled)
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func row(for block: TranslatedBlock, role: TextRole) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.hair + 1) {
            if showSource, block.sourceText != block.translatedText {
                Text(block.sourceText)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(block.translatedText)
                .font(font(for: role))
                .foregroundStyle(role == .caption ? .secondary : .primary)
                .lineSpacing(role == .body ? 3 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, topPadding(for: role))
        .contentShape(Rectangle())
        .onTapGesture { onCorrect(block) }
        .accessibilityAddTraits(role == .heading ? .isHeader : [])
    }

    private func font(for role: TextRole) -> Font {
        switch role {
        case .heading: return .title3.weight(.semibold)
        case .body: return .body
        case .caption: return .footnote
        }
    }

    /// Space above a run, so headings separate sections instead of running on.
    private func topPadding(for role: TextRole) -> CGFloat {
        switch role {
        case .heading: return Theme.Space.xl - Theme.Space.xs
        case .body: return Theme.Space.s
        case .caption: return Theme.Space.xs + 2
        }
    }
}
