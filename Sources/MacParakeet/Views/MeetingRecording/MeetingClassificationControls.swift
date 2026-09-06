import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

struct MeetingClassificationBadges: View {
    let classification: MeetingClassification?
    var maximumLabels = 2

    var body: some View {
        if let classification, !classification.labels.isEmpty {
            HStack(spacing: 5) {
                ForEach(Array(classification.labels.prefix(maximumLabels).enumerated()), id: \.element.id) {
                    index, label in
                    badge(
                        label.name,
                        icon: nil,
                        tint: MeetingClassificationTint.color(for: label.colorToken, fallback: index + 1),
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
            MeetingLabelFilterPopover(libraryViewModel: libraryViewModel)
        }
    }

    private var labelFilterTitle: String {
        let count = libraryViewModel.selectedMeetingLabelIDs.count
        return count == 0 ? "All labels" : "Labels · \(count)"
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
    @State private var query = ""

    private var labels: [MeetingLabel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allLabels = libraryViewModel.meetingClassificationViewModel.meetingLabels
        guard !trimmed.isEmpty else { return allLabels }
        return allLabels.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        filterPopoverContainer(searchText: $query, prompt: "Search labels") {
            if labels.isEmpty {
                Text("No matching labels")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DesignSystem.Spacing.sm)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(Array(labels.enumerated()), id: \.element.id) { index, label in
                        filterChip(
                            name: label.name,
                            icon: "tag.fill",
                            tint: MeetingClassificationTint.color(
                                for: label.colorToken,
                                fallback: index + 1
                            ),
                            selected: libraryViewModel.selectedMeetingLabelIDs.contains(label.id)
                        ) {
                            libraryViewModel.toggleMeetingLabelFilter(label.id)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private func filterPopoverContainer<Content: View>(
    searchText: Binding<String>,
    prompt: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            TextField(prompt, text: searchText)
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

        content()
    }
    .padding(DesignSystem.Spacing.md)
    .frame(width: 330)
    .background(DesignSystem.Colors.contentBackground)
}

@MainActor
private func filterChip(
    name: String,
    icon: String?,
    tint: Color,
    selected: Bool,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        HStack(spacing: 5) {
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(name)
                .lineLimit(1)
        }
        .font(DesignSystem.Typography.caption.weight(.medium))
        .foregroundStyle(selected ? tint : DesignSystem.Colors.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(selected ? tint.opacity(0.16) : tint.opacity(0.07))
        )
        .overlay(
            Capsule().strokeBorder(
                selected ? tint.opacity(0.55) : tint.opacity(0.24),
                lineWidth: selected ? 1 : 0.6
            )
        )
    }
    .buttonStyle(.plain)
    .accessibilityValue(selected ? "Selected" : "Not selected")
}

struct MeetingClassificationEditor: View {
    let transcription: Transcription
    @Bindable var viewModel: MeetingClassificationViewModel
    @State private var newLabelName = ""

    private var classification: MeetingClassification {
        viewModel.classification(for: transcription.id)
            ?? MeetingClassification(meetingType: nil, labels: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Labels")
                            .font(DesignSystem.Typography.bodySmall.weight(.semibold))

                        HStack(spacing: 6) {
                            if !classification.labels.isEmpty {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 5) {
                                        ForEach(Array(classification.labels.enumerated()), id: \.element.id) {
                                            index, label in
                                            selectedLabelToken(label, index: index)
                                        }
                                    }
                                }
                                .scrollIndicators(.hidden)
                                .frame(maxWidth: .infinity)
                            }

                            TextField("Search or create a label", text: $newLabelName)
                                .textFieldStyle(.plain)
                                .frame(minWidth: 125, idealWidth: 155)
                                .onSubmit(createLabel)
                                .help("Choose an existing suggestion or press Return to create a label")
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(DesignSystem.Colors.surfaceElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.6)
                        )

                        if !trimmedLabelQuery.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(suggestedLabels) { label in
                                    Button {
                                        assignSuggestedLabel(label)
                                    } label: {
                                        HStack(spacing: 7) {
                                            Image(
                                                systemName: classification.labels.contains(where: { $0.id == label.id })
                                                    ? "checkmark"
                                                    : "tag"
                                            )
                                            .font(.system(size: 9, weight: .semibold))
                                            .frame(width: 10)
                                            Text(label.name)
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

                                if exactLabelMatch == nil {
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
                            }
                            .padding(5)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(DesignSystem.Colors.surfaceElevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                            )
                        }
                    }

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

                    Spacer(minLength: 0)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .background(DesignSystem.Colors.contentBackground)
        .onAppear {
            viewModel.loadOptions()
            viewModel.loadClassification(for: transcription.id)
        }
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
        Array(
            displayedLabels.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedLabelQuery)
            }.prefix(4))
    }

    private var exactLabelMatch: MeetingLabel? {
        displayedLabels.first {
            $0.name.compare(trimmedLabelQuery, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func selectedLabelToken(_ label: MeetingLabel, index: Int) -> some View {
        let tint = MeetingClassificationTint.color(for: label.colorToken, fallback: index + 1)
        return Button {
            viewModel.toggleLabel(label.id, for: transcription.id)
        } label: {
            HStack(spacing: 5) {
                Text(label.name)
                    .lineLimit(1)
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
        .fixedSize()
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
                                    MeetingClassificationTint.color(
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

    func body(content: Content) -> some View {
        content.popover(isPresented: isPresented, arrowEdge: .top) {
            if let viewModel {
                MeetingClassificationEditor(
                    transcription: transcription,
                    viewModel: viewModel
                )
                .frame(width: 340, height: 210)
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

enum MeetingClassificationTint {
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
