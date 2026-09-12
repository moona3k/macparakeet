import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

private struct ShareManagementEnvironmentKey: EnvironmentKey {
    static let defaultValue: ShareManagementViewModel? = nil
}

extension EnvironmentValues {
    var shareManagement: ShareManagementViewModel? {
        get { self[ShareManagementEnvironmentKey.self] }
        set { self[ShareManagementEnvironmentKey.self] = newValue }
    }
}

struct ShareTranscriptSheet: View {
    @Bindable var draft: ShareDraftViewModel
    let management: ShareManagementViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingRecovery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.updating == nil ? "Share a text snapshot" : "Update shared page")
                        .font(DesignSystem.Typography.pageTitle)
                    Text("Your Library stays on this Mac. You choose the separate copy to publish.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(draft.publication == nil ? "Cancel" : "Done") { dismiss() }
                    .parakeetAction(.secondary)
                    .disabled(draft.isPublishing)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            if let publication = draft.publication {
                success(publication)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView { options.padding(20) }.frame(width: 290)
                    Divider()
                    ScrollView {
                        if let bundle = draft.preview {
                            ShareBundlePreview(bundle: bundle).padding(24)
                        } else if draft.isPreparing {
                            ProgressView("Preparing exact preview…").padding(40)
                        } else {
                            Text("Choose the text to include. Nothing is uploaded until you publish.")
                                .foregroundStyle(.secondary).padding(24)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DesignSystem.Colors.surface)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(SharePresentationCopy.disclosure).font(.callout).foregroundStyle(.secondary)
                    if let error = draft.errorMessage { Text(error).foregroundStyle(DesignSystem.Colors.errorRed) }
                    HStack {
                        Text(
                            "Exact preview · \(ByteCountFormatter.string(fromByteCount: Int64(draft.previewBytes), countStyle: .file))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if draft.isPublishing { ProgressView().controlSize(.small) }
                        Button(draft.updating == nil ? "Publish link" : "Update shared page") {
                            Task { await draft.publish() }
                        }
                        .parakeetAction(.primary)
                        .disabled(!draft.canPublish)
                        .keyboardShortcut(.defaultAction)
                    }
                }.padding(20)
            }
        }
        .frame(width: 820, height: 640)
        .background(DesignSystem.Colors.background)
        .interactiveDismissDisabled(draft.isPublishing)
        .task { await draft.preparePreview() }
        .onChange(of: draft.manifest) { Task { await draft.preparePreview() } }
        .sheet(isPresented: $showingRecovery) { ShareRecoveryView(model: management) }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Include").font(DesignSystem.Typography.sectionTitle)
            ForEach(draft.source.summaries) { summary in
                Toggle(
                    summary.title,
                    isOn: Binding(
                        get: { draft.manifest.summaryIDs.contains(summary.id) },
                        set: { selected in
                            if selected {
                                draft.manifest.summaryIDs.append(summary.id)
                            } else {
                                draft.manifest.summaryIDs.removeAll { $0 == summary.id }
                            }
                        }
                    )
                )
                .disabled(summary.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Toggle("Notes", isOn: $draft.manifest.includeNotes)
                .disabled(
                    (draft.source.transcription.userNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            Toggle("Transcript", isOn: $draft.manifest.includeTranscript)
            Divider()
            Toggle("Timestamps", isOn: $draft.manifest.includeTimestamps)
                .disabled(!draft.manifest.includeTranscript || !draft.canIncludeTimestamps)
            Toggle("Speaker labels", isOn: $draft.manifest.includeSpeakerLabels)
                .disabled(!draft.manifest.includeTranscript || !draft.canIncludeSpeakerLabels)
            if !draft.canIncludeTimestamps {
                Text(
                    "Timing and speaker options depend on the current transcript. Edited text does not reuse old timing."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Title, date and duration", isOn: $draft.manifest.includeMetadata)
            Divider()
            if draft.updating == nil {
                Text("Available until").font(.headline)
                HStack(spacing: 6) {
                    lifetime("1h", 3600); lifetime("24h", 86400); lifetime("7d", 604800); lifetime("30d", 2592000)
                }
                DatePicker(
                    "Custom expiration", selection: $draft.expiresAt, displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                Text("Every link expires. Maximum lifetime: 90 days.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This update keeps the same link and expiration. It never publishes automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(draft.expiresAt, format: .dateTime.year().month().day().hour().minute().second()).font(.caption)
            }
            Spacer()
        }
        .toggleStyle(.checkbox)
        .disabled(draft.isPublishing)
    }

    private func lifetime(_ label: String, _ seconds: TimeInterval) -> some View {
        Button(label) { draft.selectLifetime(seconds: seconds) }.parakeetAction(.secondary).controlSize(.small)
    }

    private func success(_ publication: SharePublication) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(
                draft.link == nil
                    ? "Confirmation pending" : (draft.updating == nil ? "Your link is ready" : "Shared page updated"),
                systemImage: draft.link == nil ? "clock" : "checkmark.circle"
            )
            .font(DesignSystem.Typography.pageTitle)
            if let link = draft.link {
                ShareLinkActions(link: link)
                Text("Available until \(publication.expiresAt.formatted(date: .complete, time: .standard)).")
            } else {
                Text(
                    draft.updating == nil
                        ? "The request is kept on this Mac, but there is no confirmed link to send yet. Open Shared pages and refresh to reconcile it."
                        : "Your update is queued. The last confirmed revision remains shared until the service confirms the new one."
                )
            }
            if let error = draft.errorMessage { Text(error).foregroundStyle(.secondary) }
            Divider()
            Text(SharePresentationCopy.recovery).foregroundStyle(.secondary)
            Button("Save or manage recovery code…") { showingRecovery = true }
                .parakeetAction(.secondary)
            Text("You can also change expiration or stop this link permanently in Shared pages.").font(.callout)
            Spacer()
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ShareLinkActions: View {
    let link: MacParakeetCore.ShareLink
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("share.macparakeet.com/s/\(link.locator.rawValue.prefix(8))…")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(copied ? "Copied complete link" : "Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                    copied = true
                }.parakeetAction(.secondary)
                SwiftUI.ShareLink(item: link.url) { Label("Share…", systemImage: "square.and.arrow.up") }
                    .parakeetAction(.secondary)
                Button("Open") { NSWorkspace.shared.open(link.url) }.parakeetAction(.secondary)
            }
        }
    }
}

private struct ShareBundlePreview: View {
    let bundle: ShareBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let title = bundle.title { Text(title).font(DesignSystem.Typography.pageTitle) }
            if let source = bundle.source {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.kind.rawValue.capitalized)
                    if let date = source.displayDate {
                        Text(date, format: .dateTime.year().month().day().hour().minute().second())
                    }
                    if let duration = source.durationMs { Text("Duration: \(duration) ms") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(bundle.sections.enumerated()), id: \.offset) { _, section in
                switch section {
                case .summary(let title, let markdown), .notes(let title, let markdown):
                    Text(title).font(DesignSystem.Typography.sectionTitle)
                    Text(markdown).textSelection(.enabled)
                case .transcript(let title, let segments):
                    Text(title).font(DesignSystem.Typography.sectionTitle)
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        VStack(alignment: .leading, spacing: 4) {
                            if let start = segment.startMs, let end = segment.endMs {
                                Text("\(time(start))–\(time(end))").font(.caption).foregroundStyle(.secondary)
                            }
                            if let speaker = segment.speaker { Text(speaker).font(.headline) }
                            Text(segment.text).textSelection(.enabled)
                        }
                    }
                }
            }
            Text("Snapshot prepared \(bundle.publishedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func time(_ milliseconds: Int) -> String {
        String(format: "%02d:%02d.%03d", milliseconds / 60000, (milliseconds / 1000) % 60, milliseconds % 1000)
    }
}
