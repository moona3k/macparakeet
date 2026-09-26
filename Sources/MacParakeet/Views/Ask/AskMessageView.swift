import SwiftUI
import MacParakeetCore

struct AskMessageView: View {
    let message: AskMessage
    let onCitation: (AskEvidenceReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message.role == .user ? "You" : "Ask")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if message.role == .assistant {
                MarkdownContentView(message.content)
                if let provider = message.provider {
                    Text("Model: \(provider.name) · \(provider.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.citations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sources")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(message.citations.indices, id: \.self) { index in
                        citationButton(index)
                    }
                }
            }
            if message.status != .complete {
                Label(
                    message.failureReason ?? statusMessage,
                    systemImage: message.status == .cancelled ? "stop.circle" : "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var statusMessage: String {
        switch message.status {
        case .complete: return ""
        case .incomplete: return "This answer may be incomplete. Check its cited passages."
        case .failed: return "Answer incomplete after an error."
        case .cancelled: return "Stopped before completion."
        }
    }

    private func citationButton(_ index: Int) -> some View {
        let reference = message.citations[index]
        return Button {
            onCitation(reference)
        } label: {
            HStack(spacing: 6) {
                Text("[\(index + 1)]")
                    .fontWeight(.semibold)
                Text(reference.sourceTitle ?? "Source")
                    .lineLimit(1)
                if let date = reference.recordedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .font(.caption)
        }
        .parakeetAction(.secondary)
        .help("Open supporting passage")
        .accessibilityLabel(citationAccessibilityLabel(reference, index: index))
    }

    private func citationAccessibilityLabel(_ reference: AskEvidenceReference, index: Int) -> String {
        var label = "Open citation \(index + 1), \(reference.sourceTitle ?? "source")"
        if let date = reference.recordedAt {
            label += ", \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return label
    }
}
