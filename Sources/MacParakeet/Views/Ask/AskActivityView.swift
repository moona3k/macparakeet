import SwiftUI
import MacParakeetCore

/// A quiet, inspectable record of actual source operations, separate from answer text.
struct AskActivityView: View {
    let activities: [AskActivity]
    var phase: AskRunPhase?
    var isRunning = false
    var isStopping = false
    var status: AskMessage.Status = .complete
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    statusIcon
                        .frame(width: 16, height: 16)
                    Text(title)
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.leading)
                    if !activities.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .padding(.vertical, 6)
            }
            .parakeetAction(.subtle)
            .disabled(activities.isEmpty)
            .accessibilityLabel(title)
            .accessibilityValue(activities.isEmpty ? "" : (isExpanded ? "Expanded" : "Collapsed"))
            .accessibilityHint(activities.isEmpty ? "" : "Show or hide recording activity")
            .accessibilityIdentifier("ask.activity.disclosure")

            if isExpanded, !activities.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(activities) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: stepIcon(step))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stepTitle(step))
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let detail = stepDetail(step) {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if activities.count >= 32 {
                        Text("Showing the first 32 steps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 10)
                .padding(.trailing, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(DesignSystem.Colors.border).frame(width: 1)
                }
                .padding(.leading, 7)
                .padding(.bottom, 6)
                .textSelection(.enabled)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if isRunning, !reduceMotion {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: isRunning ? "ellipsis" : terminalIcon)
                .font(.system(size: 12, weight: .medium))
        }
    }

    private var title: String {
        if isStopping { return "Stopping…" }
        if isRunning {
            if let current = activities.last(where: { $0.status == .running }) {
                return stepTitle(current)
            }
            switch phase {
            case .writing: return "Writing answer…"
            case .validating: return "Checking references…"
            case .planning, .none:
                return activities.isEmpty ? "Checking your question…" : "Reviewing results…"
            }
        }
        switch status {
        case .cancelled: return "Stopped · View activity"
        case .failed: return "Couldn’t finish · View activity"
        case .incomplete: return "Incomplete answer · View activity"
        case .complete:
            let count = activities.filter { $0.status == .complete }.count
            return "View activity · \(count) \(count == 1 ? "step" : "steps")"
        }
    }

    private var terminalIcon: String {
        switch status {
        case .complete: return "checkmark"
        case .cancelled: return "stop.circle"
        case .failed, .incomplete: return "exclamationmark.circle"
        }
    }

    private func stepIcon(_ step: AskActivity) -> String {
        switch step.status {
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "stop.circle"
        case .running, .complete:
            switch step.tool {
            case .listSources: return "square.stack"
            case .search: return "magnifyingglass"
            case .read: return "doc.text"
            case .getSummary: return "text.alignleft"
            }
        }
    }

    private func stepTitle(_ step: AskActivity) -> String {
        let running = step.status == .running
        switch step.tool {
        case .listSources: return running ? "Checking selected recordings…" : "Selected recordings"
        case .search:
            if let query = step.query, !query.isEmpty { return "\(running ? "Searching" : "Search") “\(query)”" }
            return running ? "Searching recordings…" : "Transcript search"
        case .read:
            let source = step.sourceTitle ?? "recording"
            return running ? "Reading \(source)…" : (step.status == .complete ? "Read \(source)" : "Reading \(source)")
        case .getSummary:
            let source = step.sourceTitle ?? "recording"
            return running ? "Checking summary of \(source)…" : "Summary of \(source)"
        }
    }

    private func stepDetail(_ step: AskActivity) -> String? {
        switch step.status {
        case .running: return nil
        case .failed: return "Couldn’t complete this step"
        case .cancelled: return "Stopped before this step finished"
        case .complete:
            guard let count = step.tool == .listSources ? step.sourceCount : step.resultCount else { return "Finished" }
            let result: String
            switch step.tool {
            case .listSources: result = "\(count) selected \(count == 1 ? "recording" : "recordings")"
            case .search:
                result =
                    count == 0
                    ? "No matches for this search" : "\(count) matching \(count == 1 ? "passage" : "passages") returned"
            case .read: result = "\(count) \(count == 1 ? "passage" : "passages") returned"
            case .getSummary:
                result =
                    count == 0
                    ? "No current summary returned" : "\(count) saved \(count == 1 ? "summary" : "summaries") returned"
            }
            let scope =
                step.tool == .search
                ? step.sourceCount.map { " across \($0) \($0 == 1 ? "recording" : "recordings")" } ?? "" : ""
            return result + scope + (step.hasMore == true ? " · More available" : "")
        }
    }
}
