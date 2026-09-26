import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct AskSourcePickerView: View {
    @Bindable var model: AskWorkspaceViewModel
    @State private var searchText = ""
    @State private var kind: SourceKind = .meetings
    @State private var usesStartDate = false
    @State private var usesEndDate = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var labelIDs: Set<UUID> = []
    @State private var preview: AskSourceDescriptor?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose sources")
                        .font(.title2.weight(.semibold))
                    Text("Select the recordings Ask may use for your next question.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.pickerSelection.count) / \(AskWorkspaceViewModel.maximumSources) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            Divider()
            filters
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            Divider()
            HStack(spacing: 0) {
                results
                    .frame(maxWidth: .infinity)
                Divider()
                selectedSources
                    .frame(width: 250)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.sourcePickerError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                }
                if model.savedDraftAtConflict != nil {
                    Text("Choose which draft to keep in Ask before applying source changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Changing sources starts a new context section. Earlier answers stay in this conversation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelSourceSelection() }
                        .parakeetAction(.secondary)
                    Button(
                        model.conversation?.activeSection?.sourceIDs.isEmpty == true ? "Add sources" : "Apply changes"
                    ) {
                        Task { await model.applySourceSelection() }
                    }
                    .parakeetAction(.primaryProminent)
                    .disabled(
                        model.isStopping
                            || model.savedDraftAtConflict != nil
                            || model.pickerSelection.count > AskWorkspaceViewModel.maximumSources
                            || model.selectedSourceSnapshots.contains(where: { $0.status != .available }))
                }
            }
            .padding(18)
        }
        .frame(minWidth: 760, idealWidth: 890, minHeight: 610, idealHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $preview) { source in
            AskSourcePreviewView(source: source)
        }
        .onChange(of: searchText) { _, _ in refresh() }
        .onChange(of: kind) { _, _ in refresh() }
        .onChange(of: usesStartDate) { _, _ in refresh() }
        .onChange(of: usesEndDate) { _, _ in refresh() }
        .onChange(of: startDate) { _, _ in refresh() }
        .onChange(of: endDate) { _, _ in refresh() }
        .onChange(of: labelIDs) { _, _ in refresh() }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("Search recording titles", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search sources")
                Picker("Source type", selection: $kind) {
                    ForEach(SourceKind.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Source type")
                .frame(width: 150)
                Menu {
                    if model.sourceLabels.isEmpty {
                        Text("No labels")
                    }
                    ForEach(model.sourceLabels) { label in
                        Button {
                            if labelIDs.contains(label.id) {
                                labelIDs.remove(label.id)
                            } else {
                                labelIDs.insert(label.id)
                            }
                        } label: {
                            Label(label.name, systemImage: labelIDs.contains(label.id) ? "checkmark" : "")
                        }
                    }
                    if !labelIDs.isEmpty {
                        Divider()
                        Button("Clear labels") { labelIDs.removeAll() }
                    }
                } label: {
                    Label(labelIDs.isEmpty ? "Labels" : "Labels \(labelIDs.count)", systemImage: "tag")
                }
                .frame(width: 120)
            }
            HStack(spacing: 12) {
                Toggle("From", isOn: $usesStartDate)
                    .toggleStyle(.checkbox)
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                    .labelsHidden()
                    .disabled(!usesStartDate)
                Toggle("Through", isOn: $usesEndDate)
                    .toggleStyle(.checkbox)
                DatePicker("Through", selection: $endDate, displayedComponents: .date)
                    .labelsHidden()
                    .disabled(!usesEndDate)
                Spacer()
            }
            .font(.caption)
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Results")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Select visible results") {
                    Task { await model.selectVisibleSources() }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(model.sourceResults.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            if model.sourceResults.isEmpty && model.isLoadingSources {
                ProgressView("Searching sources…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sourceResults.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                    Text("No matching sources")
                        .font(.headline)
                    Text("Try All sources or adjust the filters.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.sourceResults) { source in
                            sourceRow(source)
                            Divider().padding(.leading, 18)
                        }
                        if model.hasMoreSources {
                            Button(model.isLoadingSources ? "Loading…" : "Load more results") {
                                Task { await model.searchSources(loadMore: true) }
                            }
                            .parakeetAction(.secondary)
                            .disabled(model.isLoadingSources)
                            .padding(18)
                        }
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: AskSourceDescriptor) -> some View {
        let labels = model.sourceLabels.filter { source.labelIDs.contains($0.id) }.map(\.name)
        return HStack(alignment: .top, spacing: 10) {
            Toggle(
                isOn: Binding(
                    get: { model.pickerSelection.contains(source.id) },
                    set: { _ in Task { await model.toggleSource(source.id) } }
                )
            ) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!source.isAvailable && !model.pickerSelection.contains(source.id))
            .accessibilityLabel("\(source.title), \(source.recordedAt.formatted(date: .abbreviated, time: .omitted))")
            VStack(alignment: .leading, spacing: 4) {
                Text(source.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(
                    "\(source.recordedAt.formatted(date: .abbreviated, time: .shortened)) · \(source.sourceType.displayName)\(source.durationMs.map { " · \(Self.duration($0))" } ?? "")"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if !labels.isEmpty {
                    Text(labels.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !source.isAvailable {
                    Text("Transcript unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let excerpt = source.preview, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button("Preview") { preview = source }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var selectedSources: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Selected \(model.pickerSelection.count)")
                .font(.subheadline.weight(.semibold))
                .padding(14)
            Divider()
            if model.pickerSelection.isEmpty {
                Text("Choose sources from the results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.selectedSourceSnapshots, id: \.descriptor.id) { snapshot in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.descriptor.title)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(2)
                                    if snapshot.descriptor.isAvailable {
                                        Text(
                                            snapshot.descriptor.recordedAt.formatted(date: .abbreviated, time: .omitted)
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                    if snapshot.status != .available {
                                        Text("Unavailable or changed")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Button("Remove", systemImage: "xmark") {
                                    Task { await model.toggleSource(snapshot.descriptor.id) }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(snapshot.descriptor.title)")
                            }
                            .padding(12)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func refresh() {
        var filter = AskSourceFilter(
            searchText: searchText,
            sourceType: kind.sourceType,
            since: usesStartDate ? Calendar.current.startOfDay(for: startDate) : nil,
            until: usesEndDate
                ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDate)) : nil,
            labelIDs: labelIDs,
            limit: 50
        )
        filter.offset = 0
        model.setSourceFilter(filter)
    }

    private static func duration(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

private enum SourceKind: String, CaseIterable, Identifiable {
    case meetings, all, files, videos, podcasts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .meetings: "Meetings"
        case .all: "All sources"
        case .files: "Files"
        case .videos: "Videos"
        case .podcasts: "Podcasts"
        }
    }
    var sourceType: Transcription.SourceType? {
        switch self {
        case .meetings: .meeting
        case .all: nil
        case .files: .file
        case .videos: .youtube
        case .podcasts: .podcast
        }
    }
}

private extension Transcription.SourceType {
    var displayName: String {
        switch self {
        case .meeting: "Meeting"
        case .file: "File"
        case .youtube: "Video"
        case .podcast: "Podcast"
        }
    }
}

private struct AskSourcePreviewView: View {
    let source: AskSourceDescriptor
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(source.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Close", action: { dismiss() })
                    .parakeetAction(.secondary)
            }
            Text(source.recordedAt.formatted(date: .complete, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                Text(source.preview?.isEmpty == false ? source.preview! : "No preview is available for this source.")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 300)
    }
}
