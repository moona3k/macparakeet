import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

struct MeetingClassificationBadges: View {
    let classification: MeetingClassification?
    var maximumLabels = 2

    var body: some View {
        if let classification, !classification.labels.isEmpty {
            HStack(spacing: 5) {
                ForEach(classification.labels.prefix(maximumLabels)) { label in
                    badge(
                        label.name,
                        icon: nil,
                        tint: MeetingLabelTint.color(for: label),
                        isPrimary: false
                    )
                }

                let hiddenCount = classification.labels.count - maximumLabels
                if hiddenCount > 0 {
                    Text("+\(hiddenCount)")
                        .font(DesignSystem.Typography.micro.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .accessibilityLabel("\(hiddenCount) more labels")
                }
            }
        }
    }

    private func badge(_ text: String, icon: String?, tint: Color, isPrimary: Bool) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(DesignSystem.Typography.micro.weight(isPrimary ? .semibold : .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.11)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MeetingClassificationFilterBar: View {
    @Bindable var libraryViewModel: TranscriptionLibraryViewModel
    @State private var showingLabelFilters = false
    @State private var showingLabelManager = false

    var body: some View {
        HStack(spacing: 7) {
            labelMenu

            if libraryViewModel.hasMeetingClassificationFilter {
                Button("Clear") {
                    libraryViewModel.clearMeetingClassificationFilters()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .help("Clear label filters")
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcription label filters")
        .sheet(isPresented: $showingLabelManager) {
            MeetingLabelManagementSheet(viewModel: libraryViewModel.meetingClassificationViewModel)
                .frame(width: 460, height: 520)
        }
    }

    private var labelMenu: some View {
        Button {
            showingLabelFilters.toggle()
        } label: {
            filterButtonLabel(
                title: labelFilterTitle,
                icon: "tag"
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showingLabelFilters, arrowEdge: .bottom) {
            MeetingLabelFilterPopover(
                libraryViewModel: libraryViewModel,
                onDismiss: { showingLabelFilters = false },
                onManage: {
                    showingLabelFilters = false
                    showingLabelManager = true
                }
            )
        }
    }

    private var labelFilterTitle: String {
        let count = libraryViewModel.selectedMeetingLabelIDs.count
        return count == 0 ? "Labels" : "Labels · \(count)"
    }

    private func filterButtonLabel(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(DesignSystem.Typography.caption.weight(.medium))
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.surfaceElevated)
                    .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
            )
    }

}

private struct MeetingLabelFilterPopover: View {
    @Bindable var libraryViewModel: TranscriptionLibraryViewModel
    let onDismiss: () -> Void
    let onManage: () -> Void
    @State private var query = ""
    @State private var showingSelectedOnly = false
    @FocusState private var searchFocused: Bool

    private var allLabels: [MeetingLabel] {
        libraryViewModel.meetingClassificationViewModel.meetingLabels
    }

    private var labels: [MeetingLabel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allLabels.filter { label in
            (!showingSelectedOnly || libraryViewModel.selectedMeetingLabelIDs.contains(label.id))
                && (trimmed.isEmpty || label.name.localizedCaseInsensitiveContains(trimmed))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            if allLabels.isEmpty {
                noLabelsState
            } else {
                searchField

                Text("Match any selected label")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)

                Toggle("Show selected", isOn: $showingSelectedOnly)
                    .font(DesignSystem.Typography.caption)

                Divider()

                LabelPopoverOptionsViewport {
                    filterOptions
                }

                Button("Manage labels…", action: onManage)
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.accent)
            }

            if libraryViewModel.hasMeetingClassificationFilter {
                Divider()
                Button("Clear filters") {
                    libraryViewModel.clearMeetingClassificationFilters()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(width: 320)
        .background(DesignSystem.Colors.contentBackground)
        .onAppear {
            guard !allLabels.isEmpty else { return }
            Task { @MainActor in searchFocused = true }
        }
        .onExitCommand(perform: onDismiss)
    }

    private var noLabelsState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("No labels yet")
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Create labels to group meetings and filter your library.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Button("Manage labels…", action: onManage)
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.accent)
                .padding(.top, 3)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            TextField("Search labels", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.6)
        )
    }

    private var filterOptions: some View {
        VStack(alignment: .leading, spacing: 2) {
            filterRows
        }
    }

    @ViewBuilder
    private var filterRows: some View {
        if labels.isEmpty {
            Text(filterEmptyMessage)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DesignSystem.Spacing.sm)
        } else {
            ForEach(labels) { label in
                let selected = libraryViewModel.selectedMeetingLabelIDs.contains(label.id)
                Button {
                    libraryViewModel.toggleMeetingLabelFilter(label.id)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(MeetingLabelTint.color(for: label))
                            .frame(width: 8, height: 8)
                        Text(label.name)
                            .lineLimit(1)
                            .help(label.name)
                        Spacer(minLength: 0)
                        Image(systemName: selected ? "checkmark" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                selected ? MeetingLabelTint.color(for: label) : DesignSystem.Colors.textTertiary
                            )
                    }
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label.name)
                .accessibilityValue(selected ? "Selected" : "Not selected")
            }
        }
    }

    private var filterEmptyMessage: String {
        if showingSelectedOnly && libraryViewModel.selectedMeetingLabelIDs.isEmpty {
            return "No selected labels"
        }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No labels yet."
        }
        return "No matching labels"
    }
}

struct MeetingClassificationEditor: View {
    let transcription: Transcription
    @Bindable var viewModel: MeetingClassificationViewModel
    let onDismiss: () -> Void
    let onManage: () -> Void
    @State private var newLabelName = ""
    @FocusState private var searchFocused: Bool

    private var classification: MeetingClassification {
        viewModel.classification(for: transcription.id)
            ?? MeetingClassification(meetingType: nil, labels: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Labels")
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))

            searchField

            LabelPopoverOptionsViewport {
                editorOptions
            }

            Button("Manage labels…", action: onManage)
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.accent)

            if viewModel.updatingTranscriptionIDs.contains(transcription.id) {
                HStack(spacing: 7) {
                    ParakeetSpinner(.inline)
                    Text("Saving classification…")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.contentBackground)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            viewModel.loadOptions()
            viewModel.loadClassification(for: transcription.id)
            Task { @MainActor in searchFocused = true }
        }
        .onExitCommand(perform: onDismiss)
    }

    private var editorOptions: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            if !classification.labels.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(classification.labels) { label in
                        selectedLabelToken(label)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if (!classification.labels.isEmpty && !suggestedLabels.isEmpty) || canCreateLabel {
                Divider()
            }

            if canCreateLabel {
                Button(action: createLabel) {
                    Label("Create “\(trimmedLabelQuery)”", systemImage: "plus")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.accent)
            }

            if suggestedLabels.isEmpty {
                Text(suggestedLabelsEmptyMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .padding(.vertical, DesignSystem.Spacing.xs)
            } else {
                ForEach(suggestedLabels) { label in
                    availableLabelRow(label)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            TextField("Search or create a label", text: $newLabelName)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(createLabel)
                .help("Choose an existing label or press Return to create a label")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.6)
        )
    }

    private var displayedLabels: [MeetingLabel] {
        let availableIDs = Set(viewModel.meetingLabels.map(\.id))
        let assignedArchived = classification.labels.filter { !availableIDs.contains($0.id) }
        return viewModel.meetingLabels + assignedArchived
    }

    private var trimmedLabelQuery: String {
        newLabelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestedLabels: [MeetingLabel] {
        displayedLabels.filter {
            trimmedLabelQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmedLabelQuery)
        }
    }

    private var suggestedLabelsEmptyMessage: String {
        if trimmedLabelQuery.isEmpty {
            return "No labels yet. Type a name to create one."
        }
        return "No matching labels"
    }

    private var exactLabelMatch: MeetingLabel? {
        displayedLabels.first {
            $0.name.compare(trimmedLabelQuery, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private var canCreateLabel: Bool {
        !trimmedLabelQuery.isEmpty && exactLabelMatch == nil
    }

    private func selectedLabelToken(_ label: MeetingLabel) -> some View {
        let tint = MeetingLabelTint.color(for: label)
        return Button {
            viewModel.toggleLabel(label.id, for: transcription.id)
        } label: {
            HStack(spacing: 5) {
                Text(label.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180)
                    .help(label.name)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(DesignSystem.Typography.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.13)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.name)
        .accessibilityValue("Assigned")
        .accessibilityHint("Removes this label")
    }

    private func availableLabelRow(_ label: MeetingLabel) -> some View {
        let isAssigned = classification.labels.contains(where: { $0.id == label.id })
        let tint = MeetingLabelTint.color(for: label)
        return Button {
            assignSuggestedLabel(label)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(label.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(label.name)
                Spacer(minLength: 0)
                Image(systemName: isAssigned ? "checkmark" : "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isAssigned ? tint : DesignSystem.Colors.textTertiary)
            }
            .font(DesignSystem.Typography.caption.weight(.medium))
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.name)
        .accessibilityValue(isAssigned ? "Assigned" : "Available")
        .accessibilityHint(isAssigned ? "Already assigned" : "Adds this label")
        .disabled(isAssigned)
    }

    private func createLabel() {
        if let exactLabelMatch {
            assignSuggestedLabel(exactLabelMatch)
            return
        }
        let name = trimmedLabelQuery
        newLabelName = ""
        viewModel.createMeetingLabel(named: name, assigningTo: transcription.id)
    }

    private func assignSuggestedLabel(_ label: MeetingLabel) {
        if !classification.labels.contains(where: { $0.id == label.id }) {
            viewModel.toggleLabel(label.id, for: transcription.id)
        }
        newLabelName = ""
    }
}

private enum LabelPopoverOptionsLayout {
    static let maximumHeight: CGFloat = 260
}

/// Lets short label collections set the popover's natural height while keeping
/// longer collections in a bounded native scroll view.
struct LabelPopoverOptionsViewport<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content

            ScrollView {
                content
            }
            .frame(height: LabelPopoverOptionsLayout.maximumHeight)
        }
        .frame(maxHeight: LabelPopoverOptionsLayout.maximumHeight)
    }
}

private struct MeetingLabelManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: MeetingClassificationViewModel
    @State private var query = ""
    @State private var renamingLabel: MeetingLabel?
    @State private var showingNewLabel = false

    private var labels: [MeetingLabel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return viewModel.managedMeetingLabels }
        return viewModel.managedMeetingLabels.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manage labels")
                        .font(DesignSystem.Typography.sectionTitle)
                    Text("Rename and color labels across your library.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                if viewModel.isUpdatingLabels {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("New label") { showingNewLabel = true }
                    .parakeetAction(.primary)
                    .disabled(viewModel.isUpdatingLabels)

                Button("Done") { dismiss() }
                    .parakeetAction(.secondary)
            }

            searchField

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if labels.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(labels.enumerated()), id: \.element.id) { index, label in
                            labelRow(label)
                            if index < labels.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(DesignSystem.Spacing.xl)
        .background(DesignSystem.Colors.contentBackground)
        .onAppear {
            viewModel.clearError()
            viewModel.loadOptions()
        }
        .sheet(item: $renamingLabel) { label in
            MeetingLabelNameSheet(label: label, viewModel: viewModel)
                .frame(width: 360)
        }
        .sheet(isPresented: $showingNewLabel) {
            MeetingLabelNameSheet(label: nil, viewModel: viewModel)
                .frame(width: 360)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            TextField("Search labels", text: $query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        Text(
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No labels yet."
                : "No labels match \(query)."
        )
        .font(DesignSystem.Typography.bodySmall)
        .foregroundStyle(DesignSystem.Colors.textTertiary)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
    }

    private func labelRow(_ label: MeetingLabel) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Circle()
                .fill(MeetingLabelTint.color(for: label))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(label.name)
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .help(label.name)
                Text(label.isArchived ? "Archived" : labelColorDescription(label))
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }

            Spacer(minLength: 0)

            Menu {
                Button("Rename…") {
                    renamingLabel = label
                }

                Menu("Color") {
                    ForEach(MeetingLabelColorOption.allCases) { option in
                        Button {
                            Task {
                                _ = await viewModel.updateMeetingLabel(
                                    label.id,
                                    with: .color(option.token)
                                ).value
                            }
                        } label: {
                            HStack {
                                Circle()
                                    .fill(option.color(for: label))
                                    .frame(width: 8, height: 8)
                                Text(option.title)
                                if option == MeetingLabelColorOption(colorToken: label.colorToken) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Divider()

                Button(label.isArchived ? "Restore" : "Archive") {
                    Task {
                        _ = await viewModel.setMeetingLabelArchived(
                            label.id,
                            isArchived: !label.isArchived
                        ).value
                    }
                }
                .help(
                    label.isArchived
                        ? "Restore \(label.name) to new label choices."
                        : "Archive \(label.name). Existing assignments and label-targeted prompt rules are retained."
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(viewModel.isUpdatingLabels)
            .accessibilityLabel("Actions for \(label.name)")
        }
        .padding(.vertical, 8)
    }

    private func labelColorDescription(_ label: MeetingLabel) -> String {
        MeetingLabelColorOption(colorToken: label.colorToken).title
    }
}

private struct MeetingLabelNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let label: MeetingLabel?
    @Bindable var viewModel: MeetingClassificationViewModel
    @State private var name = ""
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(label == nil ? "New label" : "Rename label")
                .font(DesignSystem.Typography.sectionTitle)

            TextField("Label name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .parakeetAction(.primary)
                    .disabled(trimmedName.isEmpty || isSaving || viewModel.isUpdatingLabels)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .onAppear {
            name = label?.name ?? ""
            viewModel.clearError()
            nameFocused = true
        }
    }

    private func save() {
        guard !trimmedName.isEmpty, !isSaving, !viewModel.isUpdatingLabels else { return }
        isSaving = true
        Task {
            let saved: Bool
            if let label {
                saved = await viewModel.updateMeetingLabel(label.id, with: .rename(name)).value
            } else {
                saved = await viewModel.createMeetingLabel(named: name).value
            }
            if saved {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }
}

private enum MeetingLabelColorOption: CaseIterable, Identifiable, Hashable {
    case automatic
    case coral
    case green
    case amber
    case red
    case purple
    case blue

    init(colorToken: String?) {
        switch colorToken?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "coral", "orange": self = .coral
        case "green": self = .green
        case "amber", "yellow": self = .amber
        case "red": self = .red
        case "purple": self = .purple
        case "blue": self = .blue
        default: self = .automatic
        }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .coral: return "Coral"
        case .green: return "Green"
        case .amber: return "Amber"
        case .red: return "Red"
        case .purple: return "Purple"
        case .blue: return "Blue"
        }
    }

    var token: String? {
        switch self {
        case .automatic: return nil
        case .coral: return "coral"
        case .green: return "green"
        case .amber: return "amber"
        case .red: return "red"
        case .purple: return "purple"
        case .blue: return "blue"
        }
    }

    func color(for label: MeetingLabel) -> Color {
        guard let token else { return MeetingLabelTint.color(for: label) }
        var colored = label
        colored.colorToken = token
        return MeetingLabelTint.color(for: colored)
    }
}

struct MeetingTypesManagementCard: View {
    @Bindable var viewModel: MeetingClassificationViewModel
    @State private var newTypeName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Label("Meeting types", systemImage: "person.2")
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Spacer(minLength: 0)

                Text("\(viewModel.meetingTypes.count)")
                    .font(DesignSystem.Typography.micro.monospacedDigit())
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }

            TextField("New type — press Return", text: $newTypeName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createType)
                .help("Press Return to create this meeting type")

            if viewModel.meetingTypes.isEmpty {
                Text("No meeting types yet.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.meetingTypes.enumerated()), id: \.element.id) { index, meetingType in
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Circle()
                                .fill(
                                    MeetingTypeTint.color(
                                        for: meetingType.colorToken,
                                        fallback: index
                                    )
                                )
                                .frame(width: 7, height: 7)

                            Text(meetingType.name)
                                .font(DesignSystem.Typography.bodySmall)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Button {
                                viewModel.archiveMeetingType(meetingType.id)
                            } label: {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .help("Archive \(meetingType.name)")
                            .accessibilityLabel("Archive \(meetingType.name)")
                        }
                        .padding(.vertical, 6)

                        if index < viewModel.meetingTypes.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        .onAppear {
            viewModel.loadOptions()
        }
    }

    private func createType() {
        let name = newTypeName
        newTypeName = ""
        viewModel.createMeetingType(named: name)
    }
}

private struct MeetingTypeSearchMenu: View {
    let selectedType: MeetingType?
    let meetingTypes: [MeetingType]
    let onSelect: (UUID?) -> Void
    let onCreate: (String) -> Void

    @State private var isExpanded = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredTypes: [MeetingType] {
        guard !trimmedQuery.isEmpty else { return meetingTypes }
        return meetingTypes.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var exactMatch: MeetingType? {
        meetingTypes.first {
            $0.name.compare(trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    isExpanded.toggle()
                }
                if isExpanded {
                    Task { @MainActor in searchFocused = true }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(selectedType?.name ?? "Unclassified")
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(DesignSystem.Colors.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.6)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Meeting type")
            .accessibilityValue(selectedType?.name ?? "Unclassified")

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Search or create a type", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .onSubmit(commitQuery)

                    Divider()

                    typeRow(name: "Unclassified", id: nil)

                    ForEach(filteredTypes) { meetingType in
                        typeRow(name: meetingType.name, id: meetingType.id)
                    }

                    if !trimmedQuery.isEmpty, exactMatch == nil {
                        Divider()
                        Button {
                            createType()
                        } label: {
                            Label("Create “\(trimmedQuery)”", systemImage: "plus")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DesignSystem.Colors.accent)
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(DesignSystem.Colors.surfaceElevated)
                        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func typeRow(name: String, id: UUID?) -> some View {
        Button {
            onSelect(id)
            collapse()
        } label: {
            HStack(spacing: 7) {
                if selectedType?.id == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 10)
                }
                Text(name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commitQuery() {
        if let exactMatch {
            onSelect(exactMatch.id)
            collapse()
        } else if !trimmedQuery.isEmpty {
            createType()
        }
    }

    private func createType() {
        onCreate(trimmedQuery)
        collapse()
    }

    private func collapse() {
        isExpanded = false
        query = ""
        searchFocused = false
    }
}

private struct MeetingClassificationPopoverModifier: ViewModifier {
    @Binding var item: Transcription?
    let transcription: Transcription
    let viewModel: MeetingClassificationViewModel?
    @State private var showingLabelManager = false

    func body(content: Content) -> some View {
        content
            .popover(isPresented: isPresented, arrowEdge: .top) {
                if let viewModel {
                    MeetingClassificationEditor(
                        transcription: transcription,
                        viewModel: viewModel,
                        onDismiss: { item = nil },
                        onManage: {
                            item = nil
                            showingLabelManager = true
                        }
                    )
                    .frame(width: 340)
                }
            }
            .sheet(isPresented: $showingLabelManager) {
                if let viewModel {
                    MeetingLabelManagementSheet(viewModel: viewModel)
                        .frame(width: 460, height: 520)
                }
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { item?.id == transcription.id },
            set: { presented in
                if !presented, item?.id == transcription.id {
                    item = nil
                }
            }
        )
    }
}

extension View {
    func meetingClassificationPopover(
        item: Binding<Transcription?>,
        transcription: Transcription,
        viewModel: MeetingClassificationViewModel?
    ) -> some View {
        modifier(
            MeetingClassificationPopoverModifier(
                item: item,
                transcription: transcription,
                viewModel: viewModel
            )
        )
    }
}

struct MeetingPromptPolicyEditor: View {
    @Bindable var viewModel: MeetingsWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMeetingTypeID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prompts by Meeting Type")
                        .font(DesignSystem.Typography.sectionTitle)
                    Text("Choose which prompts are available and run automatically for each type.")
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .parakeetAction(.secondary)
            }

            Picker("Policy scope", selection: $selectedMeetingTypeID) {
                Text("All meetings (default)").tag(UUID?.none)
                ForEach(viewModel.meetingClassificationViewModel.meetingTypes) { meetingType in
                    Text(meetingType.name).tag(Optional(meetingType.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 300, alignment: .leading)

            if hiddenPromptCount > 0 {
                Text(
                    "\(hiddenPromptCount) hidden prompt\(hiddenPromptCount == 1 ? " is" : "s are") not shown. Make them visible in the Prompt Library before assigning meeting policies."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            }

            if visiblePrompts.isEmpty {
                Text(
                    viewModel.promptsViewModel.prompts.isEmpty
                        ? "No result prompts yet."
                        : "All result prompts are hidden. Make a prompt visible in the Prompt Library to configure it here."
                )
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visiblePrompts) { prompt in
                            policyRow(prompt)
                            Divider()
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                            .fill(DesignSystem.Colors.cardBackground)
                    )
                }
            }

            if let errorMessage = viewModel.meetingPolicyErrorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 640, height: 560)
        .background(DesignSystem.Colors.contentBackground)
        .onAppear { viewModel.refreshAutoNotes() }
    }

    private var visiblePrompts: [Prompt] {
        viewModel.promptsViewModel.prompts.filter(\.isVisible)
    }

    private var hiddenPromptCount: Int {
        viewModel.promptsViewModel.prompts.count - visiblePrompts.count
    }

    private func policyRow(_ prompt: Prompt) -> some View {
        let resolution = viewModel.meetingPolicyResolution(
            for: prompt,
            meetingTypeID: selectedMeetingTypeID
        )
        let hasExactPolicy = viewModel.hasExactMeetingPolicy(
            for: prompt,
            meetingTypeID: selectedMeetingTypeID
        )

        return HStack(spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.name)
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                if selectedMeetingTypeID != nil, !hasExactPolicy {
                    Text("Inherits the All meetings default")
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(
                "Available",
                isOn: Binding(
                    get: { resolution.isAvailable },
                    set: { isAvailable in
                        viewModel.setMeetingPolicy(
                            prompt: prompt,
                            meetingTypeID: selectedMeetingTypeID,
                            isAvailable: isAvailable,
                            isAutoRun: isAvailable && resolution.isAutoRun
                        )
                    }
                )
            )
            .toggleStyle(.switch)
            .fixedSize()

            Toggle(
                "Auto-run",
                isOn: Binding(
                    get: { resolution.isAutoRun },
                    set: { isAutoRun in
                        viewModel.setMeetingPolicy(
                            prompt: prompt,
                            meetingTypeID: selectedMeetingTypeID,
                            isAvailable: resolution.isAvailable,
                            isAutoRun: isAutoRun
                        )
                    }
                )
            )
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(!resolution.isAvailable)

            if let selectedMeetingTypeID, hasExactPolicy {
                Button {
                    viewModel.resetMeetingTypePolicy(
                        prompt: prompt,
                        meetingTypeID: selectedMeetingTypeID
                    )
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .help("Reset to All meetings default")
                .accessibilityLabel("Reset \(prompt.name) policy to default")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 11)
    }
}

enum MeetingLabelTint {
    enum ColorKey: Equatable {
        case coral
        case green
        case amber
        case red
        case purple
        case blue
        case automatic(Int)
    }

    static func color(for label: MeetingLabel) -> Color {
        color(for: colorKey(for: label))
    }

    static func colorKey(for label: MeetingLabel) -> ColorKey {
        explicitColorKey(for: label.colorToken) ?? .automatic(automaticPaletteSlot(for: label.id))
    }

    static func automaticPaletteSlot(for id: UUID) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return Int(hash % UInt64(DesignSystem.Colors.speakerColors.count))
    }

    private static func explicitColorKey(for token: String?) -> ColorKey? {
        switch token?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "coral", "orange": return .coral
        case "green": return .green
        case "amber", "yellow": return .amber
        case "red": return .red
        case "purple": return .purple
        case "blue": return .blue
        default: return nil
        }
    }

    private static func color(for key: ColorKey) -> Color {
        switch key {
        case .coral: return DesignSystem.Colors.accent
        case .green: return DesignSystem.Colors.successGreen
        case .amber: return DesignSystem.Colors.warningAmber
        case .red: return DesignSystem.Colors.errorRed
        case .purple: return DesignSystem.Colors.podcastPurple
        case .blue: return DesignSystem.Colors.speakerColor(for: 0)
        case .automatic(let slot): return DesignSystem.Colors.speakerColor(for: slot)
        }
    }
}

enum MeetingTypeTint {
    static func color(for token: String?, fallback: Int) -> Color {
        switch token?.lowercased() {
        case "coral", "orange": return DesignSystem.Colors.accent
        case "green": return DesignSystem.Colors.successGreen
        case "amber", "yellow": return DesignSystem.Colors.warningAmber
        case "red": return DesignSystem.Colors.errorRed
        case "purple": return DesignSystem.Colors.podcastPurple
        default: return DesignSystem.Colors.speakerColor(for: fallback)
        }
    }
}
