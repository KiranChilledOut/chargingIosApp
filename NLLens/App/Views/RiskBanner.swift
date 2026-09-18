import SwiftUI
import NLLensCore

/// Warns that a screen may be trying to defraud you.
///
/// Sits over everything else, because by the time you have scrolled to a tab
/// to look for it you may already have typed your password in. It appears
/// only when there is something to say — an ordinary screen shows nothing at
/// all, since a badge on every screen is one nobody reads, and the one that
/// mattered would vanish into the habit of dismissing it.
struct RiskBanner: View {

    let assessment: RiskAssessment
    @Binding var expanded: Bool

    private var tint: Color { Theme.Palette.risk(assessment.level) }

    private var symbol: String {
        switch assessment.level {
        case .danger: return "exclamationmark.octagon.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .fine: return "checkmark.circle"
        }
    }

    var body: some View {
        VStack {
            content
                .padding(Theme.Space.l)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.large)
                        .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                )
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.s)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(Theme.Motion.settle, value: expanded)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                    Text(assessment.headline)
                        .font(Theme.Typeface.section)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.s)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse details" : "Show why")

            if expanded {
                if !assessment.signals.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(Array(assessment.signals.enumerated()), id: \.offset) { _, signal in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Circle()
                                    .fill(tint)
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 6)
                                Text(signal)
                                    .font(Theme.Typeface.detail)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if !assessment.advice.isEmpty {
                    Text(assessment.advice)
                        .font(Theme.Typeface.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
