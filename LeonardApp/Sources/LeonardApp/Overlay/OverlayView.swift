import SwiftUI
import LeonardCore

/// The one thing Leonard ever puts in front of the user uninvited: a small
/// card, top right, that never takes focus from the app they are in. The
/// title says what needs them; the detail says why now; the button says
/// exactly what will happen.
struct OverlayView: View {
    let suggestion: Suggestion
    var explanation: String?
    let onPrepare: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                LeonardMark(size: 16, color: Theme.attention)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !suggestion.detail.isEmpty {
                        Text(suggestion.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.t(.overlayIgnore), action: onDismiss)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(suggestion.cta ?? L10n.t(.overlayPrepare), action: onPrepare)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .fixedSize()
    }
}
