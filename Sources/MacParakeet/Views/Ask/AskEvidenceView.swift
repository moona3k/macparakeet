import Foundation
import SwiftUI
import MacParakeetCore

struct AskEvidenceView: View {
    let evidence: AskEvidence?
    let isLoading: Bool
    let onClose: () -> Void
    let onOpenSource: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Evidence")
                    .font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .parakeetAction(.subtle)
                    .accessibilityLabel("Close evidence")
            }
            .padding(18)
            Divider()
            if isLoading {
                ProgressView("Loading passage…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let evidence {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let source = evidence.source {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.title)
                                    .font(.title3.weight(.semibold))
                                    .textSelection(.enabled)
                                if source.isAvailable {
                                    Text(source.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if source.isAvailable {
                                Button("Open in Library", systemImage: "arrow.up.right.square") {
                                    onOpenSource(source.id)
                                }
                                .parakeetAction(.secondary)
                            }
                        }
                        if evidence.status == .available, let passage = evidence.passage {
                            if let startMs = passage.startMs {
                                Label(Self.timecode(startMs), systemImage: "clock")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            } else {
                                Label("Text passage", systemImage: "text.alignleft")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            if let speaker = passage.speaker {
                                Text(speaker)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(passage.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Label(statusMessage(evidence.status), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            } else {
                Text("Choose a citation to inspect its source passage.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statusMessage(_ status: AskEvidenceStatus) -> String {
        switch status {
        case .available: return "This passage is unavailable."
        case .unavailable: return "The recording or transcript is no longer available."
        case .stale:
            return "The source changed since this answer. This passage cannot be verified against the original version."
        case .outOfScope: return "This passage is outside the conversation's source set."
        case .invalid: return "This passage reference is invalid."
        }
    }

    private static func timecode(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
