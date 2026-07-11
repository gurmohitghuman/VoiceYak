import SwiftUI

/// The "Last Transcription" card shared by the menu popover (compact) and
/// the dashboard (regular): header, copy button with a 1.5 s "copied"
/// reset, and the transcription text.
struct LastTranscriptionCard: View {
    enum Style {
        case compact
        case regular
    }

    let text: String
    let style: Style

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 6 : 10) {
            HStack {
                Text("Last Transcription")
                    .font(style == .compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    didCopy = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopy = false
                    }
                } label: {
                    if style == .compact {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(didCopy ? Color.green : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    } else {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(didCopy ? Color.green : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
                .accessibilityLabel("Copy last transcription")
            }

            Group {
                if style == .compact {
                    Text(text.prefix(150) + (text.count > 150 ? "…" : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(style == .compact ? 10 : 18)
        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }
}
