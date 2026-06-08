import Foundation
import Sparkle
import SwiftUI
import AppKit
import MacParakeetCore
import MacParakeetViewModels

enum SettingsHotkeyConflictMessage {
    static func disabled(conflictingWith rowName: String, trigger: HotkeyTrigger) -> String {
        "Disabled — conflicts with \(rowName) (\(trigger.formattedLabel))."
    }

    static func blocked(conflictingWith rowName: String, trigger: HotkeyTrigger) -> String {
        "Conflicts with \(rowName) (\(trigger.formattedLabel))."
    }
}

enum SettingsDictationHotkeyConflictPolicy {
    static func validation(
        candidate: HotkeyTrigger,
        peer: HotkeyTrigger,
        peerName: String
    ) -> HotkeyTrigger.ValidationResult? {
        guard candidate.overlaps(with: peer) else { return nil }
        if HotkeyTrigger.isSharedDictationGesture(handsFree: candidate, pushToTalk: peer) {
            return nil
        }
        return .blocked(SettingsHotkeyConflictMessage.blocked(
            conflictingWith: peerName,
            trigger: peer
        ))
    }

    static func existingConflictMessage(
        trigger: HotkeyTrigger,
        peer: HotkeyTrigger,
        peerName: String,
        disablesTrigger: Bool
    ) -> String? {
        guard trigger.overlaps(with: peer) else { return nil }
        if HotkeyTrigger.isSharedDictationGesture(handsFree: trigger, pushToTalk: peer) {
            return nil
        }
        if disablesTrigger {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: peerName,
                trigger: peer
            )
        }
        return SettingsHotkeyConflictMessage.blocked(
            conflictingWith: peerName,
            trigger: peer
        )
    }
}

enum SettingsDictationHotkeyDisplay {
    static func pushToTalkDisplayLabelOverride(
        pushToTalk: HotkeyTrigger,
        handsFree: HotkeyTrigger
    ) -> String? {
        guard HotkeyTrigger.isSharedDictationGesture(
            handsFree: handsFree,
            pushToTalk: pushToTalk
        ) else {
            return nil
        }
        guard !HotkeyTrigger.isDefaultDictationGesturePreset(
            handsFree: handsFree,
            pushToTalk: pushToTalk
        ) else {
            return nil
        }
        return "Hold \(sharedGestureKeyLabel(for: pushToTalk))"
    }

    static func handsFreeDisplayLabelOverride(
        handsFree: HotkeyTrigger,
        pushToTalk: HotkeyTrigger
    ) -> String? {
        guard HotkeyTrigger.isSharedDictationGesture(
            handsFree: handsFree,
            pushToTalk: pushToTalk
        ) else {
            return nil
        }
        return "Double-tap \(sharedGestureKeyLabel(for: handsFree))"
    }

    static func handsFreeDefaultLabelOverride(
        pushToTalk: HotkeyTrigger
    ) -> String? {
        handsFreeDisplayLabelOverride(
            handsFree: .defaultDictation,
            pushToTalk: pushToTalk
        )
    }

    private static func sharedGestureKeyLabel(for trigger: HotkeyTrigger) -> String {
        switch trigger.kind {
        case .disabled:
            return "Disabled"
        case .modifier:
            if trigger.modifierName == "fn" {
                return "Fn"
            }
            return trigger.shortSymbol
        case .keyCode, .chord, .modifierChord:
            return trigger.shortSymbol
        }
    }
}

private extension SettingsCaptureWorkflow {
    var title: LocalizedStringKey {
        switch self {
        case .dictation: "Dictation"
        case .transcription: "Transcription"
        case .meetings: "Meetings"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: "waveform"
        case .transcription: "doc.text"
        case .meetings: "record.circle"
        }
    }
}

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var llmSettingsViewModel: LLMSettingsViewModel
    let updater: SPUUpdater
    let transformHotkeys: [Prompt]
    let requestedTab: SettingsTab?
    let requestedAnchor: String?
    let requestedTabRevision: Int
    let onRequestedTabConsumed: () -> Void
    /// Fired by each `HotkeyRecorderView` when it starts/stops capturing
    /// keystrokes. Wired up to `AppHotkeyCoordinator.suspend` / `resume` so
    /// active global taps don't swallow the keyDown the user is recording.
    let onHotkeyRecordingStateChanged: (Bool) -> Void

    @State private var rootViewModel = SettingsRootViewModel()
    @FocusState private var searchFieldFocused: Bool
    /// Set when a search-result row is tapped. Each tab's `ScrollView`
    /// watches this via `.task(id:)`; whichever ScrollView is on screen
    /// when this transitions to a non-nil anchor scrolls itself there
    /// and clears the target. Using `task(id:)` (not `onChange`) so it
    /// fires both on transition AND on initial mount of the destination
    /// tab — important because tapping a result almost always triggers
    /// a tab swap, which mounts a new ScrollView.
    @State private var pendingScrollTarget: String?
    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool
    @State private var copiedBuildIdentity = false
    /// Which downloaded model a destructive confirmation is pending for. Drives
    /// the shared delete-confirmation alert on the Engine tab.
    @State private var pendingModelDeletion: PendingModelDeletion?

    init(
        viewModel: SettingsViewModel,
        llmSettingsViewModel: LLMSettingsViewModel,
        updater: SPUUpdater,
        transformHotkeys: [Prompt] = [],
        requestedTab: SettingsTab? = nil,
        requestedAnchor: String? = nil,
        requestedTabRevision: Int = 0,
        onRequestedTabConsumed: @escaping () -> Void = {},
        onHotkeyRecordingStateChanged: @escaping (Bool) -> Void
    ) {
        self.viewModel = viewModel
        self.llmSettingsViewModel = llmSettingsViewModel
        self.updater = updater
        self.transformHotkeys = transformHotkeys
        self.requestedTab = requestedTab
        self.requestedAnchor = requestedAnchor
        self.requestedTabRevision = requestedTabRevision
        self.onRequestedTabConsumed = onRequestedTabConsumed
        self.onHotkeyRecordingStateChanged = onHotkeyRecordingStateChanged
        self._rootViewModel = State(initialValue: SettingsRootViewModel(initialTab: requestedTab))
        self._automaticallyChecksForUpdates = State(initialValue: updater.automaticallyChecksForUpdates)
        self._automaticallyDownloadsUpdates = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeaderShell
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.sm)

            // The tab bar stays visible during search so the user can
            // bail back to a tab at any time. Search results replace
            // the tab body; pending scroll targets only fire after the
            // user picks a result and the destination tab mounts.
            //
            // The animation crossfades the body when entering/exiting
            // search. Tab-to-tab swaps stay snappy: only `isSearching`
            // is animated, not `activeTab`.
            Group {
                if rootViewModel.isSearching {
                    SettingsSearchResultsList(
                        results: SettingsSearchIndex.matches(rootViewModel.searchQuery),
                        onSelect: handleSearchResultTap
                    )
                } else {
                    switch rootViewModel.activeTab {
                    case .capture:
                        captureTabContent
                    case .engine:
                        engineTabContent
                    case .ai:
                        aiTabContent
                    case .system:
                        systemTabContent
                    }
                }
            }
            .animation(DesignSystem.Animation.contentSwap, value: rootViewModel.isSearching)
        }
        .background(DesignSystem.Colors.background)
        .background(focusSearchHotkey)
        .onAppear {
            viewModel.refreshLaunchAtLoginStatus()
            viewModel.startPermissionPolling()
            viewModel.refreshStats()
            viewModel.refreshEntitlements()
            viewModel.refreshModelStatus()
            viewModel.refreshPendingMeetingRecoveries()
        }
        .onDisappear {
            viewModel.stopPermissionPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
            viewModel.refreshSpeechEngineSwitchAvailability()
            Task { await viewModel.refreshCalendarNotificationAuthorization() }
        }
        .onAppear {
            if requestedTab != nil || requestedAnchor != nil {
                openRequestedSettingsDestination(tab: requestedTab, anchor: requestedAnchor)
                onRequestedTabConsumed()
            }
        }
        .onChange(of: requestedTabRevision) { _, _ in
            if requestedTab != nil || requestedAnchor != nil {
                openRequestedSettingsDestination(tab: requestedTab, anchor: requestedAnchor)
                onRequestedTabConsumed()
            }
        }
    }

    // MARK: - Tabbed Shell

    /// Top-of-panel header: tab bar on the left, search field on the right.
    /// Tab badges roll up the worst per-card status the user can act on.
    /// `.ok` / `.info` are intentionally silent on the badges — a
    /// permanent green dot would just be visual debt.
    private var settingsHeaderShell: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            SettingsTabBar(
                activeTab: tabBindingExitingSearch,
                tabBadges: tabBadges
            )

            // The search field reserves a clickable width first; the tab bar —
            // whose per-button `.fixedSize` already keeps its labels from
            // wrapping — fills whatever remains. The previous arrangement gave
            // the *tab bar* layout priority, so its `maxWidth: .infinity`
            // segments ate the entire row even in wide windows, collapsing the
            // search field to an icon-only stub with no hittable text area.
            // Reserving the field's width keeps it usable at every size.
            SettingsSearchField(
                query: $rootViewModel.searchQuery,
                isFocused: $searchFieldFocused
            )
            .frame(minWidth: 200, maxWidth: 280)
            .layoutPriority(1)
        }
    }

    /// Per-tab attention badges. Only `.required` and `.recommended`
    /// surface here — they're the two states that mean "the user has
    /// something to do on this tab." `resetCleanupCard`'s `.required
    /// "Destructive"` chip is intentionally excluded: the chip is a
    /// severity *label* on a deliberate destination, not an action item.
    /// Wraps `rootViewModel.activeTab` so that any tab tap during search
    /// also exits search mode. Without this, the body stays gated on
    /// `isSearching` first and the tab pill slides over to the new tab
    /// while the search results remain on screen — the click looks
    /// accepted but nothing useful happens. `clearSearch()` is a no-op
    /// when not searching, so non-search tab taps are unaffected.
    private var tabBindingExitingSearch: Binding<SettingsTab> {
        Binding(
            get: { rootViewModel.activeTab },
            set: { newTab in
                rootViewModel.activeTab = newTab
                rootViewModel.clearSearch()
            }
        )
    }

    private var tabBadges: [SettingsTab: SettingsStatusChip.Status] {
        var badges: [SettingsTab: SettingsStatusChip.Status] = [:]

        var captureStatuses: [SettingsCardStatus?] = [
            viewModel.microphoneGranted
                ? SettingsCardStatus(.ok, label: "Granted")
                : SettingsCardStatus(.required, label: "Permission required")
        ]
        if AppFeatures.meetingRecordingEnabled {
            captureStatuses.append(meetingRecordingCardStatus)
        }
        if let badge = Self.attentionBadge(for: captureStatuses) {
            badges[.capture] = badge
        }

        if let badge = Self.attentionBadge(for: [
            engineSelectorCardStatus,
            enginesModelsCardStatus
        ]) {
            badges[.engine] = badge
        }

        if let badge = Self.attentionBadge(for: [aiProviderCardStatus]) {
            badges[.ai] = badge
        }

        if let badge = Self.attentionBadge(for: [permissionsCardStatus]) {
            badges[.system] = badge
        }

        return badges
    }

    /// Picks the worst actionable severity from a card-status list, or
    /// returns nil when nothing is actionable (`.ok` / `.info` / no chip
    /// at all). Static so it can't accidentally read view state.
    private static func attentionBadge(for statuses: [SettingsCardStatus?]) -> SettingsStatusChip.Status? {
        let actual = statuses.compactMap { $0?.status }
        if actual.contains(.required) { return .required }
        if actual.contains(.recommended) { return .recommended }
        return nil
    }

    /// Search-result tap handler. Order of operations matters:
    /// 1. Set the scroll target so `task(id:)` on the destination tab's
    ///    ScrollView sees a non-nil value when it mounts.
    /// 2. Switch to the result's tab — this swaps the body away from
    ///    the search results and into the destination tab's ScrollView.
    /// 3. Clear the search query — this also drops `isSearching` to
    ///    false. SwiftUI batches these so the user perceives one swap.
    private func handleSearchResultTap(_ entry: SettingsSearchEntry) {
        if entry.tab == .capture, let section = captureSection(for: entry.cardAnchor) {
            rootViewModel.activeCaptureWorkflow = section
        }
        pendingScrollTarget = normalizedScrollAnchor(for: entry.cardAnchor, tab: entry.tab)
        rootViewModel.activeTab = entry.tab
        rootViewModel.clearSearch()
    }

    private func openRequestedSettingsDestination(tab: SettingsTab?, anchor: String?) {
        let destinationTab = tab ?? rootViewModel.activeTab
        if destinationTab == .capture, let anchor, let section = captureSection(for: anchor) {
            rootViewModel.activeCaptureWorkflow = section
        }
        if let anchor {
            pendingScrollTarget = normalizedScrollAnchor(for: anchor, tab: destinationTab)
        }
        rootViewModel.open(tab: destinationTab)
    }

    private func normalizedScrollAnchor(for anchor: String, tab: SettingsTab) -> String {
        guard tab == .capture, let section = captureSection(for: anchor) else {
            return anchor
        }
        switch section {
        case .dictation:
            return "dictation"
        case .transcription:
            return "transcription"
        case .meetings:
            return "meeting"
        }
    }

    private func captureSection(for anchor: String) -> SettingsCaptureWorkflow? {
        if anchor.hasPrefix("dictation") {
            return .dictation
        }
        if anchor.hasPrefix("transcription") {
            return .transcription
        }
        if anchor.hasPrefix("meeting") {
            return AppFeatures.meetingRecordingEnabled ? .meetings : nil
        }
        return nil
    }

    /// Hidden button that registers ⌘F as a focus shortcut. Lives in a
    /// `.background` so it's not visible but still reachable by the
    /// keyboard-shortcut dispatcher. macOS convention.
    private var focusSearchHotkey: some View {
        Button("Focus Search") {
            searchFieldFocused = true
        }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Capture tab — daily-ops config for the three product workflows. The
    /// shared microphone strip stays above the workflow picker because input is
    /// a capture prerequisite, not a fourth mode.
    private var captureTabContent: some View {
        scrollableTabBody {
            captureMicrophoneStrip.id("audio.input")
            captureWorkflowSwitcher

            Group {
                switch displayedCaptureWorkflow {
                case .dictation:
                    dictationCard.id("dictation")
                case .transcription:
                    transcriptionCard.id("transcription")
                case .meetings:
                    if AppFeatures.meetingRecordingEnabled {
                        meetingRecordingCard.id("meeting")
                    }
                }
            }
            .animation(DesignSystem.Animation.contentSwap, value: rootViewModel.activeCaptureWorkflow)
        }
    }

    /// Engine tab — speech recognition stack, decomposed into three cards
    /// so each surface owns one decision the user makes:
    ///
    /// 1. `engineSelectorCard` — which engine? (Parakeet vs Nemotron vs Whisper)
    /// 2. `engineParakeetModelCard` — which Parakeet build? (Parakeet only —
    ///    multilingual `v3` vs English-only `v2`)
    /// 3. `engineLanguageCard` — which language? (Whisper only — Parakeet
    ///    auto-detects from its 25 supported European languages)
    /// 4. `enginesModelsCard` — what's the local model state?
    ///
    /// Cards 2 and 3 are mutually exclusive (one per engine), so exactly one
    /// contextual config card sits between the selector and the models card.
    ///
    /// Sub-VM split (`EngineSettingsViewModel`) lands in a later commit;
    /// the cards keep reading from `viewModel` for now.
    private var engineTabContent: some View {
        scrollableTabBody {
            engineSelectorCard.id("engine.selector")
            engineParakeetModelCard.id("engine.parakeetModel")
            engineLanguageCard.id("engine.language")
            enginesModelsCard.id("engine.models")
        }
        .alert(
            modelDeletionAlertTitle,
            isPresented: Binding(
                get: { pendingModelDeletion != nil },
                set: { if !$0 { pendingModelDeletion = nil } }
            ),
            presenting: pendingModelDeletion
        ) { deletion in
            Button("Cancel", role: .cancel) { pendingModelDeletion = nil }
            Button("Delete", role: .destructive) { performModelDeletion(deletion) }
        } message: { deletion in
            Text(modelDeletionMessage(for: deletion))
        }
        .alert(
            speechEngineSwitchConfirmationTitle,
            isPresented: Binding(
                get: { viewModel.pendingSpeechEngineSwitchConfirmation != nil },
                set: { if !$0 { viewModel.cancelPendingSpeechEngineSwitchConfirmation() } }
            ),
            presenting: viewModel.pendingSpeechEngineSwitchConfirmation
        ) { engine in
            Button("Cancel", role: .cancel) {
                viewModel.cancelPendingSpeechEngineSwitchConfirmation()
            }
            Button("Switch to \(engine.displayName)") {
                withAnimation(DesignSystem.Animation.contentSwap) {
                    viewModel.confirmPendingSpeechEngineSwitch()
                }
            }
        } message: { engine in
            Text(speechEngineSwitchConfirmationMessage(for: engine))
        }
    }

    /// A downloaded model awaiting delete confirmation. `parakeet` carries the
    /// specific build; Whisper deletion follows the configured Whisper variant
    /// from `SettingsViewModel.deleteWhisperModel()`, so the alert copy stays
    /// variant-agnostic here.
    private enum PendingModelDeletion: Identifiable, Equatable {
        case parakeet(ParakeetModelVariant)
        case nemotron
        case whisper

        var id: String {
            switch self {
            case .parakeet(let variant): "parakeet-\(variant.rawValue)"
            case .nemotron: "nemotron"
            case .whisper: "whisper"
            }
        }
    }

    /// Names the model in the alert title; falls back to a generic title once
    /// the alert is dismissed and `pendingModelDeletion` is nil.
    private var modelDeletionAlertTitle: String {
        switch pendingModelDeletion {
        case .parakeet(let variant): "Delete \(variant.modelName)?"
        case .nemotron: "Delete the Nemotron model?"
        case .whisper: "Delete the Whisper model?"
        case nil: "Delete this model?"
        }
    }

    private func modelDeletionMessage(for deletion: PendingModelDeletion) -> String {
        switch deletion {
        case .parakeet(let variant):
            return "This frees \(variant.approximateDownloadSize). You can download \(variant.modelName) again at any time."
        case .nemotron:
            let variant = SpeechEnginePreference.defaultNemotronModelVariant
            return "This frees \(variant.approximateDownloadSize). You can download \(variant.modelName) again at any time."
        case .whisper:
            return "This removes the configured Whisper model download from this Mac. You can download it again at any time."
        }
    }

    private func performModelDeletion(_ deletion: PendingModelDeletion) {
        switch deletion {
        case .parakeet(let variant):
            viewModel.deleteParakeetVariant(variant)
        case .nemotron:
            viewModel.deleteNemotronModel()
        case .whisper:
            viewModel.deleteWhisperModel()
        }
        pendingModelDeletion = nil
    }

    private var speechEngineSwitchConfirmationTitle: String {
        guard let engine = viewModel.pendingSpeechEngineSwitchConfirmation else {
            return "Switch speech engine?"
        }
        return "Switch to \(engine.displayName)?"
    }

    private func speechEngineSwitchConfirmationMessage(for engine: SpeechEnginePreference) -> String {
        switch engine {
        case .nemotron:
            return "Nemotron 3.5 is a Beta engine. It may take a moment to download or load, and transcript quality can vary while benchmarks are in progress. Dictation, file transcription, and meetings pause until the switch finishes."
        case .whisper:
            if viewModel.whisperHasBeenOptimized {
                return "Whisper may take a moment to load. Dictation, file transcription, and meetings pause until the switch finishes."
            }
            return "Preparing Whisper can take several minutes the first time while Core ML optimizes it for this Mac. Dictation, file transcription, and meetings pause until the switch finishes."
        case .parakeet:
            return "Switching back to Parakeet reloads the speech engine. Dictation, file transcription, and meetings pause until the switch finishes."
        }
    }

    /// AI tab — optional setup for summaries, chat, prompt actions, and Ask.
    /// The card body owns the guided local/API/CLI paths. The tab badge stays
    /// quiet unless a real connection test fails; AI is opt-in and should not
    /// create speculative warnings.
    private var aiTabContent: some View {
        scrollableTabBody {
            aiProviderCard.id("ai.provider")
        }
    }

    /// System tab — everything that isn't daily-ops, ordered by frequency of
    /// use. The destructive `resetCleanupCard` lives at the very bottom and
    /// fences itself with a red trash icon, a red "Destructive" chip, and a
    /// per-action confirmation alert — no extra pre-card divider needed.
    private var systemTabContent: some View {
        scrollableTabBody {
            appearanceCard.id("system.appearance")
            startupCard.id("system.startup")
            permissionsCard.id("system.permissions")
            storageCard.id("system.storage")
            updatesCard.id("system.updates")
            privacyCard.id("system.privacy")
            onboardingCard.id("system.onboarding")
            aboutCard.id("system.about")
            resetCleanupCard.id("system.reset")
        }
    }

    /// Common scaffold for all four tab bodies: ScrollView wrapped in a
    /// `ScrollViewReader`, with a `.task(id: pendingScrollTarget)` that
    /// scrolls to a search-result anchor when the parent sets one.
    ///
    /// Using `task(id:)` (not `onChange`) means we react both to in-tab
    /// transitions AND to the destination tab's freshly-mounted ScrollView
    /// — important because tapping a search result usually triggers a
    /// tab swap, mounting a new ScrollView that needs to scroll to a
    /// target the parent set just before the swap.
    @ViewBuilder
    private func scrollableTabBody<Content: View>(
        @ViewBuilder _ cards: @escaping () -> Content
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    cards()
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .task(id: pendingScrollTarget) {
                guard let target = pendingScrollTarget else { return }
                // Tiny delay so the destination ScrollView has had a
                // layout pass before we ask it to scroll. Without this,
                // scrollTo on a freshly-mounted ScrollView is a no-op
                // because the target id isn't registered yet.
                try? await Task.sleep(nanoseconds: 50_000_000)
                withAnimation(DesignSystem.Animation.contentSwap) {
                    proxy.scrollTo(target, anchor: .top)
                }
                pendingScrollTarget = nil
            }
        }
    }

    // MARK: - Appearance

    private var appearanceCard: some View {
        settingsCard(
            title: "Appearance",
            subtitle: "Choose how MacParakeet looks across app windows.",
            icon: "circle.lefthalf.filled"
        ) {
            SettingsRow(
                title: "Theme",
                detail: viewModel.appAppearanceMode.detail
            ) {
                Picker("Theme", selection: $viewModel.appAppearanceMode) {
                    ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayTitle).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
                .accessibilityHint("Choose whether MacParakeet follows macOS or uses a fixed light or dark appearance.")
            }
        }
    }

    // MARK: - Capture

    private var availableCaptureSections: [SettingsCaptureWorkflow] {
        SettingsCaptureWorkflow.allCases.filter { section in
            section != .meetings || AppFeatures.meetingRecordingEnabled
        }
    }

    private var displayedCaptureWorkflow: SettingsCaptureWorkflow {
        if availableCaptureSections.contains(rootViewModel.activeCaptureWorkflow) {
            return rootViewModel.activeCaptureWorkflow
        }
        return .dictation
    }

    private var captureMicrophoneStrip: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "mic")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystem.Colors.accent.opacity(0.12))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text("Microphone")
                            .font(DesignSystem.Typography.body.weight(.semibold))
                        SettingsStatusChip(
                            status: viewModel.microphoneGranted ? .ok : .required,
                            label: viewModel.microphoneGranted ? "Granted" : "Permission required"
                        )
                    }
                    Text(viewModel.selectedMicrophoneStatusText)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)

                Spacer(minLength: DesignSystem.Spacing.md)

                HStack(spacing: DesignSystem.Spacing.sm) {
                    Picker("Microphone", selection: $viewModel.selectedMicrophoneDeviceUID) {
                        Text("System Default").tag(SettingsViewModel.systemDefaultMicrophoneSelection)
                        ForEach(viewModel.microphoneDeviceOptions) { device in
                            Text(device.displayName).tag(device.uid)
                                .disabled(!device.isAvailable)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)

                    Button {
                        viewModel.refreshMicrophoneDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .parakeetAction(.secondary)
                    .help("Refresh microphones")
                    .accessibilityLabel("Refresh microphones")
                }
            }

            Divider()

            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    microphoneLevelMeter(level: viewModel.microphoneTestLevel)
                    Text(microphoneTestTitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(microphoneTestDetailColor)
                        .lineLimit(1)
                        .frame(minWidth: 82, alignment: .leading)
                }

                Spacer()

                Button {
                    switch viewModel.microphoneTestState {
                    case .testing:
                        viewModel.cancelMicrophoneTest()
                    default:
                        viewModel.testSelectedMicrophone()
                    }
                } label: {
                    Label(
                        viewModel.microphoneTestState == .testing ? "Stop" : "Test Input",
                        systemImage: viewModel.microphoneTestState == .testing ? "stop.fill" : "waveform"
                    )
                }
                .parakeetAction(.primaryProminent)
                .disabled(!viewModel.microphoneGranted && viewModel.microphoneTestState != .testing)
                .help(microphoneTestDetail)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var captureWorkflowSwitcher: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Capture workflow")
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            HStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(availableCaptureSections) { section in
                    captureWorkflowButton(section)
                }
            }
        }
        .id("capture.workflow")
    }

    private func captureWorkflowButton(_ section: SettingsCaptureWorkflow) -> some View {
        let isActive = section == displayedCaptureWorkflow
        return Button {
            rootViewModel.activeCaptureWorkflow = section
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? DesignSystem.Colors.accent : DesignSystem.Colors.textTertiary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)

                Text(section.title)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(isActive ? DesignSystem.Colors.accentLight : DesignSystem.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(
                        isActive ? DesignSystem.Colors.accent.opacity(0.75) : DesignSystem.Colors.border.opacity(0.55),
                        lineWidth: isActive ? 1 : 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityHint("Shows settings for this capture workflow")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - Microphone Helpers

    private var microphoneTestTitle: String {
        switch viewModel.microphoneTestState {
        case .idle:
            return "Input test"
        case .testing:
            return "Listening..."
        case .succeeded:
            return "Input detected"
        case .failed:
            return "Input test failed"
        }
    }

    private var microphoneTestDetail: String {
        switch viewModel.microphoneTestState {
        case .idle:
            return viewModel.microphoneGranted ? "Run a short level check before recording." : "Grant microphone permission before testing."
        case .testing:
            return "Speak into the selected microphone."
        case .succeeded:
            return "This microphone is producing audio."
        case .failed(let message):
            return message
        }
    }

    private var microphoneTestDetailColor: Color {
        switch viewModel.microphoneTestState {
        case .failed:
            return DesignSystem.Colors.errorRed
        default:
            return .secondary
        }
    }

    private func microphoneLevelMeter(level: Float) -> some View {
        GeometryReader { proxy in
            let clamped = CGFloat(max(0, min(1, level)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignSystem.Colors.surfaceElevated)
                Capsule()
                    .fill(DesignSystem.Colors.accent)
                    .frame(width: max(6, proxy.size.width * clamped))
                    .animation(.easeOut(duration: 0.12), value: clamped)
            }
        }
        .frame(width: 96, height: 8)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue("\(Int(max(0, min(1, level)) * 100)) percent")
    }

    // MARK: - Startup

    /// OS-integration card in System tab. Renamed from the legacy
    /// `generalCard` and stripped of "Show idle pill" (which moved to the
    /// Dictation card during the IA refactor — the idle pill is a
    /// dictation-UX choice, not OS chrome).
    private var startupCard: some View {
        settingsCard(
            title: "Startup",
            subtitle: "How MacParakeet shows up on your Mac at sign-in.",
            icon: "power"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                settingsToggleRow(
                    title: "Launch at login",
                    detail: "Start MacParakeet automatically when you sign in.",
                    isOn: $viewModel.launchAtLogin
                )

                if !viewModel.launchAtLoginDetail.isEmpty || viewModel.launchAtLoginError != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        if !viewModel.launchAtLoginDetail.isEmpty {
                            Text(viewModel.launchAtLoginDetail)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let error = viewModel.launchAtLoginError {
                            Text(error)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.errorRed)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                settingsToggleRow(
                    title: "Menu bar only mode",
                    detail: "Hide the Dock icon and run from the menu bar only.",
                    isOn: $viewModel.menuBarOnlyMode
                )
            }
        }
    }

    // MARK: - Dictation

    private var dictationCard: some View {
        settingsCard(
            title: "Dictation",
            subtitle: "Global shortcuts and silence behavior.",
            icon: "waveform"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Push to talk",
                        detail: "Hold to dictate, release to stop."
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorderView(
                            trigger: $viewModel.pushToTalkHotkeyTrigger,
                            defaultTrigger: .defaultPushToTalk,
                            displayLabelOverride: pushToTalkHotkeyDisplayLabelOverride,
                            additionalValidation: { candidate in
                                pushToTalkHotkeyValidation(for: candidate)
                            },
                            onRecordingStateChanged: onHotkeyRecordingStateChanged
                        )

                        if let conflict = pushToTalkHotkeyConflictMessage(for: viewModel.pushToTalkHotkeyTrigger) {
                            hotkeyConflictText(conflict)
                        }
                    }
                }

                Divider()

                HStack(alignment: .center) {
                    rowText(
                        title: "Hands-free mode",
                        detail: handsFreeHotkeyDetail
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorderView(
                            trigger: $viewModel.hotkeyTrigger,
                            defaultTrigger: .defaultDictation,
                            displayLabelOverride: handsFreeHotkeyDisplayLabelOverride,
                            defaultLabelOverride: handsFreeHotkeyDefaultLabelOverride,
                            additionalValidation: { candidate in
                                dictationHotkeyValidation(for: candidate)
                            },
                            onRecordingStateChanged: onHotkeyRecordingStateChanged
                        )

                        if let conflict = dictationHotkeyConflictMessage(for: viewModel.hotkeyTrigger) {
                            hotkeyConflictText(conflict)
                        }
                    }
                }

                if !viewModel.hotkeyTrigger.isDisabled || !viewModel.pushToTalkHotkeyTrigger.isDisabled {
                    Divider()

                    dictationModeGuide
                }

                Divider()

                // Relocated from the legacy `generalCard` during the IA
                // refactor. The idle pill *is* the dictation summon button,
                // so it belongs alongside the dictation hotkey, not in the
                // OS-integration startup section.
                settingsToggleRow(
                    title: "Show dictation pill at all times",
                    detail: "When off, the pill hides until you use a dictation shortcut.",
                    isOn: $viewModel.showIdlePill
                )

                Divider()

                settingsToggleRow(
                    title: "Pause media while dictating",
                    detail: "Pauses playing media during dictation and resumes it when capture stops.",
                    isBeta: true,
                    isOn: $viewModel.pauseMediaDuringDictation
                )

                Divider()

                settingsToggleRow(
                    title: "Instant dictation",
                    detail: "Keeps dictation ready so it starts faster and is less likely to miss your first words. macOS will show the microphone indicator while this is on.",
                    isBeta: true,
                    isOn: $viewModel.instantDictationEnabled
                )

                Divider()

                settingsToggleRow(
                    title: "Auto-stop after silence",
                    detail: "Stops recording when speech pauses for the selected delay.",
                    isOn: $viewModel.silenceAutoStop
                )

                if viewModel.silenceAutoStop {
                    Divider()
                    HStack(alignment: .center) {
                        rowText(
                            title: "Silence delay",
                            detail: "How long silence must persist before dictation stops."
                        )
                        Spacer(minLength: DesignSystem.Spacing.md)
                        Picker("Silence delay", selection: $viewModel.silenceDelay) {
                            Text("1 sec").tag(1.0)
                            Text("1.5 sec").tag(1.5)
                            Text("2 sec").tag(2.0)
                            Text("3 sec").tag(3.0)
                            Text("5 sec").tag(5.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }

                Divider()

                settingsToggleRow(
                    title: "Keep dictation on clipboard",
                    detail: "Leaves the same text MacParakeet pastes on the clipboard, useful when remote desktops need a manual ⌘V.",
                    isOn: $viewModel.keepDictationOnClipboard
                )
            }
        }
    }

    // MARK: - Transcription

    private var meetingRecordingCard: some View {
        SettingsCard(
            title: "Meeting Recording",
            subtitle: "Dedicated controls for meeting audio capture.",
            icon: "record.circle",
            status: meetingRecordingCardStatus
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Meeting hotkey",
                        detail: "Global shortcut that immediately starts or stops meeting recording."
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorderView(
                            trigger: $viewModel.meetingHotkeyTrigger,
                            defaultTrigger: .defaultMeetingRecording,
                            additionalValidation: { candidate in
                                meetingHotkeyValidation(for: candidate)
                            },
                            onRecordingStateChanged: onHotkeyRecordingStateChanged
                        )

                        if let conflict = meetingHotkeyConflictMessage(for: viewModel.meetingHotkeyTrigger) {
                            hotkeyConflictText(conflict)
                        }
                    }
                }

                Divider()

                HStack(alignment: .center) {
                    rowText(
                        title: "Audio sources",
                        detail: viewModel.meetingAudioSourceMode.detail
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    Picker("Audio sources", selection: $viewModel.meetingAudioSourceMode) {
                        ForEach(MeetingAudioSourceMode.allCases, id: \.self) { mode in
                            Text(mode.displayTitle).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                }

                if viewModel.pendingMeetingRecoveryCount > 0 {
                    Divider()

                    HStack(alignment: .center) {
                        rowText(
                            title: "Pending recovery",
                            detail: "\(viewModel.pendingMeetingRecoveryCount) partial recording\(viewModel.pendingMeetingRecoveryCount == 1 ? "" : "s")"
                        )
                        Spacer(minLength: DesignSystem.Spacing.md)
                        Button {
                            viewModel.requestPendingMeetingRecovery()
                        } label: {
                            Label("Recover", systemImage: "arrow.clockwise")
                        }
                        .parakeetAction(.secondary)
                    }
                }

                Divider()

                settingsToggleRow(
                    title: "Auto-save meetings to disk",
                    detail: "Automatically write a file to the chosen folder after every meeting recording completes.",
                    isOn: $viewModel.meetingAutoSave
                )

                if viewModel.meetingAutoSave {
                    meetingAutoSaveOptionsView
                }

                if AppFeatures.calendarEnabled {
                    Divider()

                    // Calendar section folded in from the legacy standalone
                    // `calendarCard`. Calendar is meeting-only — folding it
                    // here removes a card without losing any controls.
                    meetingCalendarSection
                }
            }
        }
    }

    /// Header status chip for the Meeting Recording card. Surfaces the
    /// screen-recording-permission state since system audio capture is
    /// gated on it.
    private var meetingRecordingCardStatus: SettingsCardStatus? {
        SettingsStatusRules.meetingRecordingCardStatus(
            meetingRecordingEnabled: AppFeatures.meetingRecordingEnabled,
            screenRecordingGranted: viewModel.screenRecordingGranted
        )
    }

    /// Calendar auto-start controls, rendered inline within the Meeting
    /// Recording card after the auto-save section. Visually demoted to a
    /// section heading so it reads as part of meeting setup.
    private var meetingCalendarSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Calendar auto-start")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            CalendarSettingsView(viewModel: viewModel)
        }
    }

    private var meetingAutoSaveOptionsView: some View {
        autoSaveOptions(
            format: $viewModel.meetingAutoSaveFormat,
            folderPath: viewModel.meetingAutoSaveFolderPath,
            formatDetail: "File format for saved meetings.",
            panelMessage: "Select a folder for auto-saved meeting recordings",
            resetHelp: "Reset to the default folder (~/Documents/MacParakeet/Meetings)",
            onChooseFolder: { viewModel.chooseMeetingAutoSaveFolder(url: $0) },
            onResetFolder: { viewModel.resetMeetingAutoSaveFolder() }
        )
    }

    private var transcriptionCard: some View {
        settingsCard(
            title: "Transcription",
            subtitle: "Options for file and video URL transcription.",
            icon: "doc.text"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                transcriptionHotkeyRow(
                    title: "File transcription hotkey",
                    detail: "Opens the file picker from anywhere on macOS.",
                    trigger: $viewModel.fileTranscriptionHotkeyTrigger,
                    otherTranscriptionTrigger: viewModel.youtubeTranscriptionHotkeyTrigger,
                    otherTranscriptionName: "video URL transcription"
                )

                Divider()

                transcriptionHotkeyRow(
                    title: "Video URL transcription hotkey",
                    detail: "Opens the video URL panel from anywhere on macOS.",
                    trigger: $viewModel.youtubeTranscriptionHotkeyTrigger,
                    otherTranscriptionTrigger: viewModel.fileTranscriptionHotkeyTrigger,
                    otherTranscriptionName: "file transcription"
                )

                Divider()

                HStack(alignment: .center) {
                    rowText(
                        title: "Video download audio quality",
                        detail: viewModel.youtubeAudioQuality.detail
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    Picker("Video download audio quality", selection: $viewModel.youtubeAudioQuality) {
                        ForEach(YouTubeAudioQuality.allCases, id: \.self) { quality in
                            Text(quality.displayTitle).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 170, idealWidth: 210, maxWidth: 260)
                }

                Divider()

                settingsToggleRow(
                    title: "Speaker detection",
                    detail: "Optional. Adds speaker labels when audio is clear; leave off if labels are unreliable.",
                    isOn: $viewModel.speakerDiarization
                )

                Divider()

                settingsToggleRow(
                    title: "Notify when transcription finishes",
                    detail: "Play a sound when a file, YouTube, or batch transcription completes — plus a notification banner when MacParakeet is in the background.",
                    isOn: $viewModel.notifyOnTranscriptionComplete
                )

                Divider()

                settingsToggleRow(
                    title: "Auto-save transcripts to disk",
                    detail: "Automatically write a file to the chosen folder after every transcription completes.",
                    isOn: $viewModel.autoSaveTranscripts
                )

                if viewModel.autoSaveTranscripts {
                    autoSaveOptionsView
                }
            }
        }
    }

    /// A transcription-hotkey row with a recorder and an inline conflict
    /// warning when the trigger collides with dictation, meeting, or the
    /// other transcription hotkey. Default trigger is `.disabled` — users opt
    /// in by recording a key.
    private func transcriptionHotkeyRow(
        title: String,
        detail: String,
        trigger: Binding<HotkeyTrigger>,
        otherTranscriptionTrigger: HotkeyTrigger,
        otherTranscriptionName: String
    ) -> some View {
        HStack(alignment: .center) {
            rowText(title: title, detail: detail)
            Spacer(minLength: DesignSystem.Spacing.md)
            VStack(alignment: .trailing, spacing: 4) {
                HotkeyRecorderView(
                    trigger: trigger,
                    defaultTrigger: .disabled,
                    additionalValidation: { candidate in
                        guard !candidate.isDisabled else { return .allowed }
                        if candidate.conflicts(with: viewModel.hotkeyTrigger, otherMode: .bareModifierDictation) {
                            return .blocked(SettingsHotkeyConflictMessage.blocked(
                                conflictingWith: "hands-free mode",
                                trigger: viewModel.hotkeyTrigger
                            ))
                        }
                        if candidate.conflicts(
                            with: viewModel.pushToTalkHotkeyTrigger,
                            otherMode: .bareModifierDictation
                        ) {
                            return .blocked(SettingsHotkeyConflictMessage.blocked(
                                conflictingWith: "push to talk",
                                trigger: viewModel.pushToTalkHotkeyTrigger
                            ))
                        }
                        if AppFeatures.meetingRecordingEnabled, candidate.overlaps(with: viewModel.meetingHotkeyTrigger) {
                            return .blocked(SettingsHotkeyConflictMessage.blocked(
                                conflictingWith: "meeting recording",
                                trigger: viewModel.meetingHotkeyTrigger
                            ))
                        }
                        if candidate.overlaps(with: otherTranscriptionTrigger) {
                            return .blocked(SettingsHotkeyConflictMessage.blocked(
                                conflictingWith: otherTranscriptionName,
                                trigger: otherTranscriptionTrigger
                            ))
                        }
                        if let conflict = transformHotkeyConflict(for: candidate) {
                            return .blocked(SettingsHotkeyConflictMessage.blocked(
                                conflictingWith: conflict.name,
                                trigger: conflict.trigger
                            ))
                        }
                        return .allowed
                    },
                    onRecordingStateChanged: onHotkeyRecordingStateChanged
                )

                if let conflict = conflictMessage(
                    trigger: trigger.wrappedValue,
                    otherTranscription: otherTranscriptionTrigger,
                    otherTranscriptionName: otherTranscriptionName
                ) {
                    transcriptionHotkeyConflictText(conflict)
                }
            }
        }
    }

    private func conflictMessage(
        trigger: HotkeyTrigger,
        otherTranscription: HotkeyTrigger,
        otherTranscriptionName: String
    ) -> String? {
        guard !trigger.isDisabled else { return nil }
        if trigger.conflicts(with: viewModel.hotkeyTrigger, otherMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "hands-free mode",
                trigger: viewModel.hotkeyTrigger
            )
        }
        if trigger.conflicts(with: viewModel.pushToTalkHotkeyTrigger, otherMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "push to talk",
                trigger: viewModel.pushToTalkHotkeyTrigger
            )
        }
        if AppFeatures.meetingRecordingEnabled, trigger.overlaps(with: viewModel.meetingHotkeyTrigger) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "meeting recording",
                trigger: viewModel.meetingHotkeyTrigger
            )
        }
        if trigger.overlaps(with: otherTranscription) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: otherTranscriptionName,
                trigger: otherTranscription
            )
        }
        if let conflict = transformHotkeyConflict(for: trigger) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            )
        }
        return nil
    }

    private func dictationHotkeyValidation(for candidate: HotkeyTrigger) -> HotkeyTrigger.ValidationResult {
        guard !candidate.isDisabled else { return .allowed }
        if let result = SettingsDictationHotkeyConflictPolicy.validation(
            candidate: candidate,
            peer: viewModel.pushToTalkHotkeyTrigger,
            peerName: "push to talk"
        ) {
            return result
        }
        if AppFeatures.meetingRecordingEnabled,
           candidate.conflicts(with: viewModel.meetingHotkeyTrigger, selfMode: .bareModifierDictation) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "meeting recording",
                trigger: viewModel.meetingHotkeyTrigger
            ))
        }
        if candidate.conflicts(with: viewModel.fileTranscriptionHotkeyTrigger, selfMode: .bareModifierDictation) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "file transcription",
                trigger: viewModel.fileTranscriptionHotkeyTrigger
            ))
        }
        if candidate.conflicts(with: viewModel.youtubeTranscriptionHotkeyTrigger, selfMode: .bareModifierDictation) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "video URL transcription",
                trigger: viewModel.youtubeTranscriptionHotkeyTrigger
            ))
        }
        if let conflict = transformHotkeyConflict(for: candidate, triggerMode: .bareModifierDictation) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            ))
        }
        return .allowed
    }

    private func pushToTalkHotkeyValidation(for candidate: HotkeyTrigger) -> HotkeyTrigger.ValidationResult {
        guard !candidate.isDisabled else { return .allowed }
        if let result = SettingsDictationHotkeyConflictPolicy.validation(
            candidate: candidate,
            peer: viewModel.hotkeyTrigger,
            peerName: "hands-free mode"
        ) {
            return result
        }
        if AppFeatures.meetingRecordingEnabled,
           candidate.conflicts(with: viewModel.meetingHotkeyTrigger, selfMode: .bareModifierDictation) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "meeting recording",
                trigger: viewModel.meetingHotkeyTrigger
            ))
        }
        if candidate.conflicts(with: viewModel.fileTranscriptionHotkeyTrigger, selfMode: .bareModifierDictation) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "file transcription",
                trigger: viewModel.fileTranscriptionHotkeyTrigger
            ))
        }
        if candidate.conflicts(with: viewModel.youtubeTranscriptionHotkeyTrigger, selfMode: .bareModifierDictation) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "video URL transcription",
                trigger: viewModel.youtubeTranscriptionHotkeyTrigger
            ))
        }
        if let conflict = transformHotkeyConflict(for: candidate, triggerMode: .bareModifierDictation) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            ))
        }
        return .allowed
    }

    private func meetingHotkeyValidation(for candidate: HotkeyTrigger) -> HotkeyTrigger.ValidationResult {
        guard !candidate.isDisabled else { return .allowed }
        if candidate.conflicts(with: viewModel.hotkeyTrigger, otherMode: .bareModifierDictation) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "hands-free mode",
                trigger: viewModel.hotkeyTrigger
            ))
        }
        if candidate.conflicts(
            with: viewModel.pushToTalkHotkeyTrigger,
            otherMode: .bareModifierDictation
        ) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "push to talk",
                trigger: viewModel.pushToTalkHotkeyTrigger
            ))
        }
        if candidate.overlaps(with: viewModel.fileTranscriptionHotkeyTrigger) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "file transcription",
                trigger: viewModel.fileTranscriptionHotkeyTrigger
            ))
        }
        if candidate.overlaps(with: viewModel.youtubeTranscriptionHotkeyTrigger) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "video URL transcription",
                trigger: viewModel.youtubeTranscriptionHotkeyTrigger
            ))
        }
        if let conflict = transformHotkeyConflict(for: candidate) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            ))
        }
        return .allowed
    }

    private func dictationHotkeyConflictMessage(for trigger: HotkeyTrigger) -> String? {
        guard !trigger.isDisabled else { return nil }
        if let conflict = SettingsDictationHotkeyConflictPolicy.existingConflictMessage(
            trigger: trigger,
            peer: viewModel.pushToTalkHotkeyTrigger,
            peerName: "push to talk",
            disablesTrigger: false
        ) {
            return conflict
        }
        if AppFeatures.meetingRecordingEnabled,
           trigger.conflicts(with: viewModel.meetingHotkeyTrigger, selfMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "meeting recording",
                trigger: viewModel.meetingHotkeyTrigger
            )
        }
        if trigger.conflicts(with: viewModel.fileTranscriptionHotkeyTrigger, selfMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "file transcription",
                trigger: viewModel.fileTranscriptionHotkeyTrigger
            )
        }
        if trigger.conflicts(with: viewModel.youtubeTranscriptionHotkeyTrigger, selfMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "video URL transcription",
                trigger: viewModel.youtubeTranscriptionHotkeyTrigger
            )
        }
        if let conflict = transformHotkeyConflict(for: trigger, triggerMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            )
        }
        return nil
    }

    private func pushToTalkHotkeyConflictMessage(for trigger: HotkeyTrigger) -> String? {
        guard !trigger.isDisabled else { return nil }
        if let conflict = SettingsDictationHotkeyConflictPolicy.existingConflictMessage(
            trigger: trigger,
            peer: viewModel.hotkeyTrigger,
            peerName: "hands-free mode",
            disablesTrigger: true
        ) {
            return conflict
        }
        if AppFeatures.meetingRecordingEnabled,
           trigger.conflicts(with: viewModel.meetingHotkeyTrigger, selfMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "meeting recording",
                trigger: viewModel.meetingHotkeyTrigger
            )
        }
        if trigger.conflicts(with: viewModel.fileTranscriptionHotkeyTrigger, selfMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "file transcription",
                trigger: viewModel.fileTranscriptionHotkeyTrigger
            )
        }
        if trigger.conflicts(with: viewModel.youtubeTranscriptionHotkeyTrigger, selfMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "video URL transcription",
                trigger: viewModel.youtubeTranscriptionHotkeyTrigger
            )
        }
        if let conflict = transformHotkeyConflict(for: trigger, triggerMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            )
        }
        return nil
    }

    private func meetingHotkeyConflictMessage(for trigger: HotkeyTrigger) -> String? {
        guard !trigger.isDisabled else { return nil }
        if trigger.conflicts(with: viewModel.hotkeyTrigger, otherMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "hands-free mode",
                trigger: viewModel.hotkeyTrigger
            )
        }
        if trigger.conflicts(with: viewModel.pushToTalkHotkeyTrigger, otherMode: .bareModifierDictation) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "push to talk",
                trigger: viewModel.pushToTalkHotkeyTrigger
            )
        }
        if trigger.overlaps(with: viewModel.fileTranscriptionHotkeyTrigger) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "file transcription",
                trigger: viewModel.fileTranscriptionHotkeyTrigger
            )
        }
        if trigger.overlaps(with: viewModel.youtubeTranscriptionHotkeyTrigger) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "video URL transcription",
                trigger: viewModel.youtubeTranscriptionHotkeyTrigger
            )
        }
        if let conflict = transformHotkeyConflict(for: trigger) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            )
        }
        return nil
    }

    private func transformHotkeyConflict(
        for trigger: HotkeyTrigger,
        triggerMode: HotkeyTrigger.ConflictMode = .exclusive
    ) -> (name: String, trigger: HotkeyTrigger)? {
        guard !trigger.isDisabled else { return nil }
        for transform in transformHotkeys {
            guard let shortcut = transform.shortcut else { continue }
            let transformTrigger = shortcut.hotkeyTrigger
            guard !transformTrigger.isDisabled else { continue }
            if trigger.conflicts(with: transformTrigger, selfMode: triggerMode) {
                return ("Transform \(transform.name)", transformTrigger)
            }
        }
        return nil
    }

    private func transcriptionHotkeyConflictText(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
    }

    private func hotkeyConflictText(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
    }

    private var autoSaveOptionsView: some View {
        autoSaveOptions(
            format: $viewModel.autoSaveFormat,
            folderPath: viewModel.autoSaveFolderPath,
            formatDetail: "File format for saved transcripts.",
            panelMessage: "Select a folder for auto-saved transcripts",
            resetHelp: "Reset to the default folder (~/Documents/MacParakeet/Transcriptions)",
            onChooseFolder: { viewModel.chooseAutoSaveFolder(url: $0) },
            onResetFolder: { viewModel.resetAutoSaveFolder() }
        )
    }

    private func autoSaveOptions(
        format: Binding<AutoSaveFormat>,
        folderPath: String?,
        formatDetail: String,
        panelMessage: String,
        resetHelp: String,
        onChooseFolder: @escaping (URL) -> Void,
        onResetFolder: @escaping () -> Void
    ) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack {
                rowText(title: "Format", detail: formatDetail)
                Spacer(minLength: DesignSystem.Spacing.md)
                Picker("", selection: format) {
                    ForEach(AutoSaveFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                        .font(DesignSystem.Typography.body)
                    if let path = folderPath {
                        Text(path)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No folder selected")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                Button("Reset") { onResetFolder() }
                    .parakeetAction(.secondary)
                    .help(resetHelp)
                Button("Choose…") {
                    if let url = Self.presentAutoSaveFolderPicker(message: panelMessage) {
                        onChooseFolder(url)
                    }
                }
                .parakeetAction(.secondary)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    /// Open the system folder picker. Returns the chosen URL or `nil` if the
    /// user cancelled. Used by the "Choose…" button in the auto-save options row.
    static func presentAutoSaveFolderPicker(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - AI Provider

    private var aiProviderCard: some View {
        SettingsCard(
            title: "AI Setup",
            subtitle: "Optional. Powers summaries, chat, meeting Ask, and Transforms.",
            icon: "brain",
            status: aiProviderCardStatus
        ) {
            LLMSettingsView(viewModel: llmSettingsViewModel)
        }
    }

    /// AI tab is opt-in, so this never returns `.required`. We only show
    /// signal when there is something actionable: yellow when the last
    /// connection test failed, green when a saved setup exists and nothing is
    /// currently broken. Silent in the not-yet-configured state because the
    /// card body already explains the empty case.
    private var aiProviderCardStatus: SettingsCardStatus? {
        if case .error = llmSettingsViewModel.connectionTestState {
            return SettingsCardStatus(.recommended, label: "Last test failed")
        }
        if llmSettingsViewModel.isConfigured {
            return SettingsCardStatus(.ok, label: "Ready")
        }
        return nil
    }

    // MARK: - Storage

    /// Storage card is read-only stats + retention toggles. Destructive
    /// operations moved to `resetCleanupCard` so the configuration surface
    /// can stay scrollable without exposing a wipe button to a misclick.
    private var storageCard: some View {
        SettingsCard(
            title: "Storage",
            subtitle: "Retention preferences and current disk usage.",
            icon: "internaldrive"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                settingsToggleRow(
                    title: "Save dictation history",
                    detail: "When off, dictations are transcribed and pasted but not saved. Voice stats still tracked.",
                    isOn: $viewModel.saveDictationHistory
                )

                Divider()

                settingsToggleRow(
                    title: "Save audio recordings",
                    detail: "Keep audio alongside your dictation history.",
                    isOn: $viewModel.saveAudioRecordings
                )

                Divider()

                settingsToggleRow(
                    title: "Keep downloaded video audio",
                    detail: "Turn off to auto-delete downloaded audio after transcription.",
                    isOn: $viewModel.saveTranscriptionAudio
                )

                Divider()

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: DesignSystem.Spacing.md)],
                    spacing: DesignSystem.Spacing.md
                ) {
                    metricTile(
                        title: "Dictation Records",
                        value: "\(viewModel.dictationCount)",
                        detail: viewModel.dictationCount == 1 ? "entry" : "entries"
                    )

                    metricTile(
                        title: "Video Downloads",
                        value: "\(viewModel.youtubeDownloadCount)",
                        detail: viewModel.formattedYouTubeStorage
                    )
                }
            }
        }
    }

    // MARK: - Reset & Cleanup

    /// Holds every destructive operation in the app. Lives at the bottom of
    /// the System tab; the red trash icon, red "Destructive" chip, and
    /// per-action confirmation alert do all the fencing — no inner panel,
    /// no pre-card divider, no double "Reset & Cleanup" labeling.
    ///
    /// Body is two semantically labeled subgroups (Delete data vs Reset
    /// counters), each containing one or more rows. Every row follows the
    /// standard Settings rhythm: title + per-action detail on the left,
    /// destructive button on the right — the same shape as
    /// `SettingsToggleRow` so the eye doesn't have to relearn this card.
    private var resetCleanupCard: some View {
        SettingsCard(
            title: "Reset & Cleanup",
            subtitle: "Permanent. These cannot be undone.",
            icon: "trash",
            iconTint: DesignSystem.Colors.errorRed,
            status: SettingsCardStatus(.required, label: "Destructive")
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                resetSection(
                    label: "Delete data",
                    caption: "Removes saved rows. Your lifetime stats stay."
                ) {
                    resetActionRow(
                        title: "Dictation history",
                        detail: "All dictations and their audio files.",
                        action: ResetDestructiveAction(
                            buttonTitle: "Clear…",
                            accessibilityLabel: "Clear all dictations",
                            confirmationTitle: "Clear All Dictations?",
                            confirmationMessage: "This will delete all \(viewModel.dictationCount) dictation\(viewModel.dictationCount == 1 ? "" : "s"), their audio files, and any private metric-only entries. Your lifetime stats are not affected. This cannot be undone.",
                            confirmButtonLabel: "Clear All",
                            perform: viewModel.clearAllDictations
                        )
                    )

                    Divider()

                    resetActionRow(
                        title: "Transform history",
                        detail: "Saved Transform runs only. Transform definitions and shortcuts stay.",
                        action: ResetDestructiveAction(
                            buttonTitle: "Clear…",
                            accessibilityLabel: "Clear Transform history",
                            confirmationTitle: "Clear Transform History?",
                            confirmationMessage: "This will delete all saved Transform runs. Transform definitions and shortcuts are not affected. This cannot be undone.",
                            confirmButtonLabel: "Clear History",
                            perform: viewModel.clearTransformHistory
                        )
                    )

                    Divider()

                    resetActionRow(
                        title: "Downloaded video audio",
                        detail: "Saved audio files only. Transcriptions stay; audio detaches.",
                        action: ResetDestructiveAction(
                            buttonTitle: "Clear…",
                            accessibilityLabel: "Clear downloaded video audio",
                            confirmationTitle: "Clear Downloaded Video Audio?",
                            confirmationMessage: "This will delete all downloaded video audio files and detach them from existing transcriptions. This cannot be undone.",
                            confirmButtonLabel: "Clear Audio",
                            perform: viewModel.clearDownloadedYouTubeAudio
                        )
                    )
                }

                resetSection(
                    label: "Reset counters",
                    caption: "Zeros your lifetime stats. Your dictation history stays."
                ) {
                    resetActionRow(
                        title: "Lifetime voice stats",
                        detail: "Total words, time, count, and longest dictation.",
                        action: ResetDestructiveAction(
                            buttonTitle: "Reset…",
                            accessibilityLabel: "Reset lifetime voice stats",
                            confirmationTitle: "Reset Lifetime Stats?",
                            confirmationMessage: "This will zero your total words, time, count, and longest dictation. Your dictation history is not affected. This cannot be undone.",
                            confirmButtonLabel: "Reset",
                            perform: viewModel.resetLifetimeStats
                        )
                    )
                }
            }
        }
    }

    /// One destructive subgroup — small section header above a list of
    /// action rows. The header uses uppercase tracked caption styling so
    /// the eye reads it as "section label," not "title": same trick the
    /// rest of the app uses for thin section dividers.
    @ViewBuilder
    private func resetSection<Content: View>(
        label: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(caption)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: DesignSystem.Spacing.sm) {
                content()
            }
        }
    }

    /// One destructive action — title + detail on the left, button on the
    /// right. Mirrors `SettingsToggleRow` so the destructive card has the
    /// same row rhythm as the rest of Settings.
    private func resetActionRow(
        title: String,
        detail: String,
        action: ResetDestructiveAction
    ) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            rowText(title: title, detail: detail)
            Spacer(minLength: DesignSystem.Spacing.md)
            SettingsDestructiveButton(
                title: action.buttonTitle,
                accessibilityLabel: action.accessibilityLabel,
                confirmationTitle: action.confirmationTitle,
                confirmationMessage: action.confirmationMessage,
                confirmButtonLabel: action.confirmButtonLabel,
                action: action.perform
            )
        }
    }

    private struct ResetDestructiveAction {
        let buttonTitle: String
        let accessibilityLabel: String
        let confirmationTitle: String
        let confirmationMessage: String
        let confirmButtonLabel: String
        let perform: () -> Void
    }

    // MARK: - Engine

    private var engineSelectorCard: some View {
        SettingsCard(
            title: "Speech Recognition",
            subtitle: "Choose the engine that powers dictation, file transcription, and meetings.",
            icon: "cpu",
            status: engineSelectorCardStatus
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                if let banner = speechEngineSwitchBannerState {
                    speechEngineSwitchBanner(title: banner.title, detail: banner.detail)
                }

                LazyVGrid(columns: engineOptionColumns, alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    EngineOptionTile(
                        icon: "bolt.fill",
                        name: "Parakeet",
                        tagline: "Fastest local engine",
                        strengths: [
                            "English + 24 European languages",
                            "155× realtime on Apple Silicon",
                            "Best default for everyday dictation"
                        ],
                        helpText: "Best default for English and supported European languages including Spanish, French, German, and Italian. Runs locally with Core ML acceleration on Apple Silicon for the lowest-latency path.",
                        modelStatus: displayedParakeetModelStatus,
                        isSelected: viewModel.speechEnginePreference == .parakeet,
                        isBusy: viewModel.speechEngineSwitching,
                        unavailableReason: engineSwitchUnavailableReason(for: .parakeet),
                        onSelect: { selectEngine(.parakeet) }
                    )

                    EngineOptionTile(
                        icon: "sparkles",
                        name: "Nemotron 3.5",
                        tagline: "Latest multilingual (Beta)",
                        strengths: [
                            "English + many European languages",
                            "Korean, Mandarin, Japanese, Hindi",
                            "Cache-aware low-latency streaming"
                        ],
                        helpText: "Newest local NVIDIA ASR option. It supports 40 language-locales with auto detection, including Korean, Mandarin, Japanese, Hindi, Spanish, French, German, Arabic, Vietnamese, and more. It stays Beta while real-world quality is benchmarked.",
                        modelStatus: displayedNemotronModelStatus,
                        isSelected: viewModel.speechEnginePreference == .nemotron,
                        isBusy: viewModel.speechEngineSwitching,
                        unavailableReason: engineSwitchUnavailableReason(for: .nemotron),
                        onSelect: { handleNemotronTileTap() }
                    )

                    EngineOptionTile(
                        icon: "globe",
                        name: "Whisper",
                        tagline: "Broad language fallback",
                        strengths: [
                            "Korean, Japanese, Chinese, Thai +95 more",
                            "Mature mixed-language recognition",
                            "Local Whisper Large v3 Turbo"
                        ],
                        helpText: "Best for languages outside Parakeet's coverage or when a mature broad-language fallback matters more than speed. Runs locally with WhisperKit.",
                        modelStatus: displayedWhisperModelStatus,
                        isSelected: viewModel.speechEnginePreference == .whisper,
                        isBusy: viewModel.speechEngineSwitching,
                        unavailableReason: engineSwitchUnavailableReason(for: .whisper),
                        needsFirstOptimize: displayedWhisperModelStatus == .notLoaded
                            && !viewModel.whisperHasBeenOptimized,
                        onSelect: { handleWhisperTileTap() }
                    )
                }

                if let banner = nemotronDownloadBannerState {
                    EngineDownloadBanner(
                        title: "Nemotron 3.5 Beta",
                        subtitle: banner.subtitle,
                        mode: banner.mode,
                        action: { viewModel.downloadNemotronModel() }
                    )
                }

                if let banner = whisperDownloadBannerState {
                    EngineDownloadBanner(
                        title: "Whisper Large v3 Turbo",
                        subtitle: banner.subtitle,
                        mode: banner.mode,
                        action: { viewModel.downloadWhisperModel() }
                    )
                }

                if let error = viewModel.speechEngineError {
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                }
            }
        }
    }

    private var engineOptionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: DesignSystem.Spacing.md, alignment: .top)]
    }

    /// Parakeet build picker (multilingual `v3` vs English-only `v2`). Only
    /// shown when Parakeet is the active engine — symmetric to the Whisper
    /// Language card. English-only fixes the v3 auto-detect mis-firing English
    /// as another language (issues #311, #398).
    @ViewBuilder
    private var engineParakeetModelCard: some View {
        if viewModel.speechEnginePreference == .parakeet {
            SettingsCard(
                title: "Parakeet Model",
                subtitle: "Pick how Parakeet handles language. English-only is a touch faster and never mistakes English for another language.",
                icon: "character.book.closed"
            ) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    parakeetModelOptionRow(.v3)
                    Divider()
                    parakeetModelOptionRow(.v2)
                }
            }
            .transition(.opacity)
        }
    }

    private func parakeetModelOptionRow(_ variant: ParakeetModelVariant) -> some View {
        let isSelected = viewModel.parakeetModelVariant == variant
        let isDownloaded = viewModel.downloadedParakeetVariants.contains(variant)
        let downloadStatusLabel = isDownloaded
            ? "Downloaded."
            : "\(variant.approximateDownloadSize), downloads on first use."
        // The selected build is the one Parakeet loads, so it's protected; only
        // the other, already-downloaded build can be removed from here.
        let canDelete = isDownloaded && !isSelected

        return HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Button {
                selectParakeetModelVariant(variant)
            } label: {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
                        .accessibilityHidden(true)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Text(variant.modelName)
                                .font(DesignSystem.Typography.body.weight(.medium))
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            parakeetVariantStatusBadge(isDownloaded: isDownloaded, size: variant.approximateDownloadSize)
                        }
                        Text(variant.coverageSummary)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, DesignSystem.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.speechEngineSwitching)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(variant.modelName). \(variant.displayName). \(variant.coverageSummary) \(downloadStatusLabel)")
            // `.combine` can drop the wrapping Button's role, so assert it explicitly
            // alongside the selected state for VoiceOver.
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])

            if canDelete {
                ModelDeleteIconButton(
                    helpText: "Remove this Parakeet build to free \(variant.approximateDownloadSize).",
                    accessibilityLabel: "Delete \(variant.modelName) download"
                ) {
                    pendingModelDeletion = .parakeet(variant)
                }
                .padding(.top, 1)
                .disabled(viewModel.speechEngineSwitching)
            }
        }
    }

    /// Compact trailing badge: green "Downloaded" when present, amber size hint
    /// with a download glyph when the build hasn't been fetched yet.
    @ViewBuilder
    private func parakeetVariantStatusBadge(isDownloaded: Bool, size: String) -> some View {
        if isDownloaded {
            HStack(spacing: 4) {
                Circle()
                    .fill(DesignSystem.Colors.successGreen)
                    .frame(width: 6, height: 6)
                Text("Downloaded")
                    .font(DesignSystem.Typography.micro.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(size) · downloads on first use")
                    .font(DesignSystem.Typography.micro.weight(.medium))
            }
            .foregroundStyle(DesignSystem.Colors.warningAmber)
        }
    }

    /// Mirrors `selectEngine`: pre-checks switch availability so the radio never
    /// flips then reverts. The VM setter (`applyParakeetModelVariantChange`)
    /// drives the actual reload + persistence.
    private func selectParakeetModelVariant(_ variant: ParakeetModelVariant) {
        guard viewModel.parakeetModelVariant != variant,
              !viewModel.speechEngineSwitching else { return }
        Task { @MainActor in
            let availability = await viewModel.refreshSpeechEngineSwitchAvailabilityNow()
            guard availability == .available else {
                viewModel.speechEngineError = SettingsViewModel.speechEngineSwitchUnavailableMessage(for: availability)
                return
            }
            withAnimation(DesignSystem.Animation.contentSwap) {
                viewModel.parakeetModelVariant = variant
            }
        }
    }

    @ViewBuilder
    private var engineLanguageCard: some View {
        if viewModel.speechEnginePreference == .whisper {
            SettingsCard(
                title: "Whisper Language",
                subtitle: "Auto-detect works for most files. Pin a language for faster startup or mixed-language audio.",
                icon: "character.bubble"
            ) {
                HStack(alignment: .center) {
                    Text("Default language")
                        .font(DesignSystem.Typography.body)
                    Spacer(minLength: DesignSystem.Spacing.md)
                    LanguagePickerButton(
                        selection: $viewModel.whisperDefaultLanguage,
                        isDisabled: false
                    )
                }
            }
            .transition(.opacity)
        }
    }

    /// Status chip rolls up the worst severity across both engines via
    /// `SettingsStatusRules.localModelsCardStatus`. Inline action button
    /// only renders for actionable states; Repair / Re-download for healthy
    /// models tucks into a `…` menu so calm rows stay calm.
    private var enginesModelsCard: some View {
        SettingsCard(
            title: "Local Models",
            subtitle: "Models live on this Mac. No audio is sent to the cloud.",
            icon: "internaldrive",
            status: enginesModelsCardStatus
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                modelStatusRow(
                    title: "Parakeet",
                    detail: displayedParakeetModelStatusDetail,
                    status: displayedParakeetModelStatus,
                    isWorking: viewModel.parakeetRepairing,
                    actionsDisabled: viewModel.speechEngineSwitching,
                    primaryAction: displayedParakeetModelStatus == .preparing ? nil : parakeetPrimaryAction,
                    overflowActions: displayedParakeetModelStatus == .preparing ? [] : parakeetOverflowActions
                )

                Divider()

                modelStatusRow(
                    title: "Nemotron",
                    detail: displayedNemotronModelStatusDetail,
                    status: displayedNemotronModelStatus,
                    isWorking: viewModel.nemotronDownloading,
                    actionsDisabled: viewModel.speechEngineSwitching,
                    primaryAction: displayedNemotronModelStatus == .preparing ? nil : nemotronPrimaryAction,
                    overflowActions: displayedNemotronModelStatus == .preparing ? [] : nemotronOverflowActions
                )

                Divider()

                modelStatusRow(
                    title: "Whisper",
                    detail: displayedWhisperModelStatusDetail,
                    status: displayedWhisperModelStatus,
                    isWorking: viewModel.whisperDownloading,
                    actionsDisabled: viewModel.speechEngineSwitching,
                    primaryAction: displayedWhisperModelStatus == .preparing ? nil : whisperPrimaryAction,
                    overflowActions: displayedWhisperModelStatus == .preparing ? [] : whisperOverflowActions
                )
            }
        }
    }

    private var engineSelectorCardStatus: SettingsCardStatus? {
        if viewModel.speechEngineSwitching {
            return SettingsCardStatus(.recommended, label: speechEngineSwitchTitle)
        }
        if viewModel.speechEngineError != nil {
            return SettingsCardStatus(.required, label: "Action needed")
        }
        return nil
    }

    private var speechEngineSwitchBannerState: (title: String, detail: String)? {
        guard viewModel.speechEngineSwitching else { return nil }
        let phase = viewModel.speechEngineSwitchDetail ?? "Preparing speech engine..."
        return (
            speechEngineSwitchTitle,
            "\(phase) Dictation, file transcription, and meetings pause until this finishes."
        )
    }

    /// Title for the switch banner / status chip. A Parakeet *build* swap
    /// (v3 ↔ v2) keeps the engine on Parakeet, so "Switching to Parakeet" would
    /// be wrong — show "Updating Parakeet model" instead.
    private var speechEngineSwitchTitle: String {
        if viewModel.isParakeetVariantSwitch {
            return "Updating Parakeet model"
        }
        let target = currentSpeechEngineSwitchTarget
        switch target {
        case .parakeet:
            return "Switching to Parakeet"
        case .nemotron:
            return "Preparing Nemotron"
        case .whisper:
            return "Preparing Whisper"
        }
    }

    private var enginesModelsCardStatus: SettingsCardStatus? {
        SettingsStatusRules.localModelsCardStatus(
            parakeet: displayedParakeetModelStatus,
            nemotron: displayedNemotronModelStatus,
            whisper: displayedWhisperModelStatus,
            activeEngine: viewModel.speechEnginePreference
        )
    }

    private var currentSpeechEngineSwitchTarget: SpeechEnginePreference {
        viewModel.speechEngineSwitchTarget ?? viewModel.speechEnginePreference
    }

    private func engineSwitchUnavailableReason(for engine: SpeechEnginePreference) -> String? {
        guard viewModel.speechEnginePreference != engine else { return nil }
        return viewModel.speechEngineSwitchUnavailableMessage
    }

    private var displayedParakeetModelStatus: SettingsViewModel.LocalModelStatus {
        guard viewModel.speechEngineSwitching,
              currentSpeechEngineSwitchTarget == .parakeet else {
            return viewModel.parakeetStatus
        }
        return .preparing
    }

    private var displayedParakeetModelStatusDetail: String {
        guard viewModel.speechEngineSwitching,
              currentSpeechEngineSwitchTarget == .parakeet else {
            return viewModel.parakeetStatusDetail
        }
        return viewModel.speechEngineSwitchDetail ?? "Loading Parakeet with Core ML..."
    }

    private var displayedWhisperModelStatus: SettingsViewModel.LocalModelStatus {
        guard viewModel.speechEngineSwitching,
              currentSpeechEngineSwitchTarget == .whisper else {
            return viewModel.whisperModelStatus
        }
        return .preparing
    }

    private var displayedWhisperModelStatusDetail: String {
        guard viewModel.speechEngineSwitching,
              currentSpeechEngineSwitchTarget == .whisper else {
            return viewModel.whisperModelStatusDetail
        }
        return viewModel.speechEngineSwitchDetail ?? "Optimizing Whisper for this Mac..."
    }

    private var displayedNemotronModelStatus: SettingsViewModel.LocalModelStatus {
        guard viewModel.speechEngineSwitching,
              currentSpeechEngineSwitchTarget == .nemotron else {
            return viewModel.nemotronModelStatus
        }
        return .preparing
    }

    private var displayedNemotronModelStatusDetail: String {
        guard viewModel.speechEngineSwitching,
              currentSpeechEngineSwitchTarget == .nemotron else {
            return viewModel.nemotronModelStatusDetail
        }
        return viewModel.speechEngineSwitchDetail ?? "Loading Nemotron 3.5 Beta with Core ML..."
    }

    private func speechEngineSwitchBanner(title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignSystem.Spacing.md)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.warningAmber.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(DesignSystem.Colors.warningAmber.opacity(0.28), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    /// Routes a tile click through a confirmation step. The VM's eventual
    /// setter still validates and performs the actual switch, but the first tap
    /// no longer starts a potentially multi-minute engine reload by surprise.
    private func selectEngine(_ engine: SpeechEnginePreference) {
        guard viewModel.speechEnginePreference != engine,
              !viewModel.speechEngineSwitching,
              viewModel.pendingSpeechEngineSwitchConfirmation == nil else { return }
        Task { @MainActor in
            let availability = await viewModel.refreshSpeechEngineSwitchAvailabilityNow()
            guard availability == .available else {
                viewModel.speechEngineError = SettingsViewModel.speechEngineSwitchUnavailableMessage(for: availability)
                return
            }
            withAnimation(DesignSystem.Animation.contentSwap) {
                viewModel.requestSpeechEngineSwitchConfirmation(to: engine)
            }
        }
    }

    /// Drives `EngineDownloadBanner` visibility + content. Returns nil
    /// unless Whisper is the actively-selected engine — Parakeet users
    /// shouldn't be nagged to download a model they may never use; for
    /// them, Whisper's status sits in the tile footer + Local Models card
    /// and is surfaced only if they explicitly switch.
    ///
    /// When Whisper IS selected: returns nil for usable (`.ready` /
    /// `.notLoaded`) or transient (`.preparing` / `.checking` / `.unknown`)
    /// states, and a populated state when the user needs to act (download,
    /// wait, retry).
    /// The banner stays mounted across `.notDownloaded` → `.repairing` →
    /// terminal state so the action surface doesn't blink out on click.
    private var whisperDownloadBannerState: (mode: EngineDownloadBanner.Mode, subtitle: String)? {
        guard viewModel.speechEnginePreference == .whisper else { return nil }
        if viewModel.whisperDownloading {
            return (.downloading, viewModel.whisperModelStatusDetail)
        }
        switch viewModel.whisperModelStatus {
        case .notDownloaded:
            return (.download, "632 MB · downloads once, runs locally afterwards")
        case .repairing:
            return (.downloading, viewModel.whisperModelStatusDetail)
        case .failed:
            return (.retry, viewModel.whisperModelStatusDetail)
        case .ready, .notLoaded, .preparing, .checking, .unknown:
            return nil
        }
    }

    private var nemotronDownloadBannerState: (mode: EngineDownloadBanner.Mode, subtitle: String)? {
        guard viewModel.speechEnginePreference == .nemotron else { return nil }
        if viewModel.nemotronDownloading {
            return (.downloading, viewModel.nemotronModelStatusDetail)
        }
        switch viewModel.nemotronModelStatus {
        case .notDownloaded:
            return (.download, "\(SpeechEnginePreference.defaultNemotronModelVariant.approximateDownloadSize) · Beta model, downloads once and runs locally")
        case .repairing:
            return (.downloading, viewModel.nemotronModelStatusDetail)
        case .failed:
            return (.retry, viewModel.nemotronModelStatusDetail)
        case .ready, .notLoaded, .preparing, .checking, .unknown:
            return nil
        }
    }

    /// Pre-empts every "Whisper isn't ready" state so the user never sees
    /// a briefly-selected-then-reverted tile. Mirrors the VM's
    /// `isWhisperModelAvailable` (`ready` or `notLoaded`); for everything
    /// else we set a state-specific inline message and leave the user on
    /// Parakeet. `.checking` and `.unknown` are transient inspections that
    /// usually settle within a frame, so we let those fall through to the
    /// VM's normal accept/revert path rather than rejecting prematurely.
    private func handleWhisperTileTap() {
        switch viewModel.whisperModelStatus {
        case .ready, .notLoaded:
            selectEngine(.whisper)
        case .notDownloaded:
            viewModel.speechEngineError = "Download the Whisper model from Local Models below before switching engines."
        case .repairing:
            viewModel.speechEngineError = "Whisper model is downloading — switch engines once it finishes."
        case .preparing:
            viewModel.speechEngineError = "Whisper is preparing for this Mac — switch engines once it finishes."
        case .failed:
            viewModel.speechEngineError = "Whisper model failed to load — retry below."
        case .checking, .unknown:
            selectEngine(.whisper)
        }
    }

    private func handleNemotronTileTap() {
        switch viewModel.nemotronModelStatus {
        case .ready, .notLoaded:
            selectEngine(.nemotron)
        case .notDownloaded:
            viewModel.speechEngineError = "Download the Nemotron model from Local Models below before switching engines."
        case .repairing:
            viewModel.speechEngineError = "Nemotron model is downloading — switch engines once it finishes."
        case .preparing:
            viewModel.speechEngineError = "Nemotron is preparing for this Mac — switch engines once it finishes."
        case .failed:
            viewModel.speechEngineError = "Nemotron model failed to load — retry below."
        case .checking, .unknown:
            selectEngine(.nemotron)
        }
    }

    private var parakeetPrimaryAction: ModelRowAction? {
        switch viewModel.parakeetStatus {
        case .failed:
            return ModelRowAction(
                label: "Retry",
                isProminent: true,
                help: "Re-run Parakeet setup and load the model again."
            ) {
                viewModel.repairParakeetModel()
            }
        case .notDownloaded:
            return ModelRowAction(
                label: "Download",
                isProminent: true,
                help: "Download and load the local Parakeet model."
            ) {
                viewModel.repairParakeetModel()
            }
        default:
            return nil
        }
    }

    /// Parakeet's Local Models overflow keeps just "Repair…". Per-build delete
    /// lives in the Parakeet Model card, where each build is listed with its own
    /// download badge — that's the unambiguous place to remove the build you're
    /// not using (this row represents whichever build is active).
    private var parakeetOverflowActions: [ModelRowAction] {
        switch viewModel.parakeetStatus {
        case .ready, .notLoaded:
            return [ModelRowAction(
                label: "Repair…",
                isProminent: false,
                help: "Re-validate the Parakeet files and load the model again."
            ) {
                viewModel.repairParakeetModel()
            }]
        default:
            return []
        }
    }

    private var whisperPrimaryAction: ModelRowAction? {
        switch viewModel.whisperModelStatus {
        case .notDownloaded:
            return ModelRowAction(
                label: "Download",
                isProminent: true,
                help: "Download Whisper Large v3 Turbo for multilingual transcription."
            ) {
                viewModel.downloadWhisperModel()
            }
        case .failed:
            return ModelRowAction(
                label: "Retry",
                isProminent: true,
                help: "Try downloading the Whisper model again."
            ) {
                viewModel.downloadWhisperModel()
            }
        default:
            return nil
        }
    }

    private var nemotronPrimaryAction: ModelRowAction? {
        switch viewModel.nemotronModelStatus {
        case .notDownloaded:
            return ModelRowAction(
                label: "Download",
                isProminent: true,
                help: "Download Nemotron 3.5 Beta for local multilingual speech recognition."
            ) {
                viewModel.downloadNemotronModel()
            }
        case .failed:
            return ModelRowAction(
                label: "Retry",
                isProminent: true,
                help: "Try downloading the Nemotron model again."
            ) {
                viewModel.downloadNemotronModel()
            }
        default:
            return nil
        }
    }

    private var nemotronOverflowActions: [ModelRowAction] {
        switch viewModel.nemotronModelStatus {
        case .ready, .notLoaded:
            var actions = [ModelRowAction(
                label: "Repair…",
                isProminent: false,
                help: "Re-check the Nemotron files and re-download any missing model assets."
            ) {
                viewModel.downloadNemotronModel()
            }]
            if viewModel.speechEnginePreference != .nemotron {
                actions.append(ModelRowAction(
                    label: "Delete download…",
                    isProminent: false,
                    isDestructive: true,
                    help: "Remove the Nemotron model download from this Mac."
                ) {
                    pendingModelDeletion = .nemotron
                })
            }
            return actions
        default:
            return []
        }
    }

    private var whisperOverflowActions: [ModelRowAction] {
        switch viewModel.whisperModelStatus {
        case .ready, .notLoaded:
            // Symmetric with Parakeet's "Repair…" — both engines surface the
            // same affordance to the user. Underneath, Parakeet re-runs warmup
            // (which downloads if files are missing); Whisper re-runs the
            // download (no-op via HuggingFace cache when files are intact).
            // The user shouldn't have to reason about that asymmetry.
            var actions = [ModelRowAction(
                label: "Repair…",
                isProminent: false,
                help: "Re-check the Whisper files and re-download any missing model assets."
            ) {
                viewModel.downloadWhisperModel()
            }]
            // Offer delete only when Whisper isn't the active engine — deleting
            // the in-use model would force a silent re-download next time.
            if viewModel.speechEnginePreference != .whisper {
                actions.append(ModelRowAction(
                    label: "Delete download…",
                    isProminent: false,
                    isDestructive: true,
                    help: "Remove the configured Whisper model download from this Mac."
                ) {
                    pendingModelDeletion = .whisper
                })
            }
            return actions
        default:
            return []
        }
    }

    fileprivate struct ModelRowAction: Identifiable {
        var id: String { label }
        let label: String
        let isProminent: Bool
        let isDestructive: Bool
        let help: String?
        let run: () -> Void

        init(
            label: String,
            isProminent: Bool,
            isDestructive: Bool = false,
            help: String? = nil,
            run: @escaping () -> Void
        ) {
            self.label = label
            self.isProminent = isProminent
            self.isDestructive = isDestructive
            self.help = help
            self.run = run
        }
    }

    private struct ModelDeleteIconButton: View {
        let helpText: String
        let accessibilityLabel: String
        let action: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(role: .destructive, action: action) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHovered ? DesignSystem.Colors.errorRed : DesignSystem.Colors.textTertiary)
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isHovered ? DesignSystem.Colors.errorRed.opacity(0.10) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(helpText)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    /// Roll-up of the three permissions. `.required` if any feature gate is
    /// missing; Screen Recording is required for meeting recording because the
    /// runtime has no mic-only meeting fallback.
    private var permissionsCardStatus: SettingsCardStatus? {
        SettingsStatusRules.permissionsCardStatus(
            meetingRecordingEnabled: AppFeatures.meetingRecordingEnabled,
            microphoneGranted: viewModel.microphoneGranted,
            accessibilityGranted: viewModel.accessibilityGranted,
            screenRecordingGranted: viewModel.screenRecordingGranted
        )
    }

    private var permissionsCard: some View {
        let permissionsSubtitle = AppFeatures.meetingRecordingEnabled
            ? "Microphone and Accessibility are required. Screen Recording is required for meetings."
            : "Microphone and Accessibility are required."

        return SettingsCard(
            title: "Permissions",
            subtitle: permissionsSubtitle,
            icon: "lock.shield",
            status: permissionsCardStatus
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack {
                    rowText(title: "Microphone", detail: "Required for voice capture.")
                    Spacer()
                    permissionPill(granted: viewModel.microphoneGranted)
                }

                Divider()

                HStack {
                    rowText(title: "Accessibility", detail: "Required for global hotkey and paste.")
                    Spacer()
                    permissionPill(granted: viewModel.accessibilityGranted)
                }

                if AppFeatures.meetingRecordingEnabled {
                    Divider()

                    HStack {
                        rowText(
                            title: "Screen & System Audio Recording",
                            detail: "Required for meeting audio capture. MacParakeet never records your screen."
                        )
                        Spacer()
                        permissionPill(granted: viewModel.screenRecordingGranted)
                    }
                }

                let needsScreenRecordingAction = AppFeatures.meetingRecordingEnabled && !viewModel.screenRecordingGranted
                if !viewModel.accessibilityGranted || needsScreenRecordingAction {
                    Divider()
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if !viewModel.accessibilityGranted {
                            Button("Open Accessibility Settings") {
                                openAccessibilitySettings()
                            }
                            .parakeetAction(.primaryProminent)
                        }

                        if needsScreenRecordingAction {
                            Button("Enable meeting recording") {
                                viewModel.requestScreenRecordingAccess()
                            }
                            .parakeetAction(.primaryProminent)

                            Button("Open Screen Recording Settings") {
                                viewModel.openScreenRecordingSystemSettings()
                            }
                            .parakeetAction(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        settingsCard(
            title: "Privacy",
            subtitle: "Your audio and transcriptions never leave your device.",
            icon: "hand.raised"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                settingsToggleRow(
                    title: "Help improve MacParakeet",
                    detail: "Send non-identifying usage statistics like feature popularity and performance metrics. No personal data is collected.",
                    isOn: $viewModel.telemetryEnabled
                )
                Button {
                    if let url = URL(string: "https://github.com/moona3k/macparakeet/blob/main/docs/telemetry.md") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("See the full event catalog")
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.link)
                .font(DesignSystem.Typography.caption)
                .accessibilityHint("Opens the telemetry documentation on GitHub in your browser.")
            }
        }
    }

    // MARK: - Updates

    private var updatesCard: some View {
        settingsCard(
            title: "Updates",
            subtitle: "Keep MacParakeet up to date.",
            icon: "arrow.triangle.2.circlepath"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                        .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                            updater.automaticallyChecksForUpdates = newValue
                        }
                        .font(DesignSystem.Typography.body)
                }

                HStack {
                    Toggle("Automatically download updates", isOn: $automaticallyDownloadsUpdates)
                        .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                            updater.automaticallyDownloadsUpdates = newValue
                        }
                        .font(DesignSystem.Typography.body)
                        .disabled(!automaticallyChecksForUpdates)
                }

                Divider()

                HStack {
                    rowText(
                        title: "Manual check",
                        detail: "Check for a new version right now."
                    )
                    Spacer()
                    Button("Check for Updates...") {
                        updater.checkForUpdates()
                    }
                    .parakeetAction(.primaryProminent)
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
    }

    // MARK: - Onboarding

    private var onboardingCard: some View {
        settingsCard(
            title: "Setup",
            subtitle: "Re-run the guided setup if something isn't working.",
            icon: "arrow.counterclockwise"
        ) {
            HStack {
                rowText(
                    title: "Run setup again",
                    detail: "Re-opens guided setup for permissions and model download."
                )
                Spacer()
                Button("Open Setup...") {
                    NotificationCenter.default.post(name: .macParakeetOpenOnboarding, object: nil)
                }
                .parakeetAction(.primaryProminent)
            }
        }
    }

    // MARK: - About

    private var aboutCard: some View {
        let identity = BuildIdentity.current
        return settingsCard(
            title: "About",
            subtitle: "Version info and diagnostics.",
            icon: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    SpinnerRingView(size: 18, revolutionDuration: 8.0, tintColor: DesignSystem.Colors.accent)
                        .opacity(0.6)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacParakeet \(identity.version) (\(identity.buildNumber))")
                            .font(DesignSystem.Typography.body)
                        Text("Fast, private voice for Mac")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(copiedBuildIdentity ? "Copied" : "Copy Build Info") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(buildIdentityReport(identity), forType: .string)
                        copiedBuildIdentity = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            copiedBuildIdentity = false
                        }
                    }
                    .parakeetAction(.secondary)
                }

                Divider()

                aboutRow(label: "Source", value: identity.buildSource)
                aboutRow(label: "Commit", value: identity.gitCommit)
                aboutRow(label: "Built", value: identity.buildDateUTC)
                aboutRow(label: "Executable", value: identity.executablePath)
            }
        }
    }

    // MARK: - Reusable UI

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsCard(title: title, subtitle: subtitle, icon: icon, content: content)
    }

    private func settingsToggleRow(
        title: String,
        detail: String,
        isBeta: Bool = false,
        isOn: Binding<Bool>
    ) -> some View {
        SettingsToggleRow(title: title, detail: detail, isBeta: isBeta, isOn: isOn)
    }

    private func rowText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.body)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metricTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.sectionTitle)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func modelStatusRow(
        title: String,
        detail: String,
        status: SettingsViewModel.LocalModelStatus,
        isWorking: Bool,
        actionsDisabled: Bool = false,
        primaryAction: ModelRowAction?,
        overflowActions: [ModelRowAction]
    ) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            HStack(spacing: DesignSystem.Spacing.sm) {
                modelStatusPill(status)
                    .help(modelStatusHelp(status))

                Group {
                    if let action = primaryAction {
                        modelRowPrimaryButton(
                            action: action,
                            isWorking: isWorking,
                            actionsDisabled: actionsDisabled
                        )
                    } else if !overflowActions.isEmpty,
                              !actionsDisabled,
                              !isWorking,
                              status != .checking,
                              status != .repairing,
                              status != .preparing {
                        Menu {
                            ForEach(overflowActions) { action in
                                Button(role: action.isDestructive ? .destructive : nil, action: action.run) {
                                    Text(action.label)
                                }
                                .help(action.help ?? action.label)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 22, height: 22)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(overflowActions.count == 1 ? (overflowActions[0].help ?? "More actions") : "More actions")
                        .accessibilityLabel("More actions")
                    } else if isWorking || status == .checking || status == .repairing || status == .preparing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 22, height: 22)
                    } else {
                        Color.clear.frame(width: 22, height: 22)
                    }
                }
                .frame(minWidth: 22, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func modelRowPrimaryButton(
        action: ModelRowAction,
        isWorking: Bool,
        actionsDisabled: Bool
    ) -> some View {
        let label = isWorking ? "Working…" : action.label
        if action.isProminent {
            Button(label, action: action.run)
                .parakeetAction(.primaryProminent)
                .controlSize(.small)
                .disabled(isWorking || actionsDisabled)
                .help(action.help ?? action.label)
        } else {
            Button(label, action: action.run)
                .parakeetAction(.secondary)
                .controlSize(.small)
                .disabled(isWorking || actionsDisabled)
                .help(action.help ?? action.label)
        }
    }

    // MARK: - Dictation Mode Guide

    private var dictationModeGuide: some View {
        VStack(spacing: 0) {
            if !viewModel.pushToTalkHotkeyTrigger.isDisabled {
                modeShortcutRow(
                    keys: [viewModel.pushToTalkHotkeyTrigger.shortSymbol],
                    separator: nil,
                    verb: "Hold",
                    action: "Push to talk",
                    detail: "Release to stop"
                )
            }

            if !viewModel.pushToTalkHotkeyTrigger.isDisabled && !viewModel.hotkeyTrigger.isDisabled {
                Divider()
                    .padding(.leading, 108)
            }

            if !viewModel.hotkeyTrigger.isDisabled {
                modeShortcutRow(
                    keys: [viewModel.hotkeyTrigger.shortSymbol],
                    separator: nil,
                    verb: usesSharedDictationGesture ? "Double-tap" : "Tap",
                    action: "Hands-free mode",
                    detail: "Tap again to stop"
                )
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private var usesSharedDictationGesture: Bool {
        HotkeyTrigger.isSharedDictationGesture(
            handsFree: viewModel.hotkeyTrigger,
            pushToTalk: viewModel.pushToTalkHotkeyTrigger
        )
    }

    private var handsFreeHotkeyDetail: String {
        if usesSharedDictationGesture {
            return "Double-tap to start; tap again to stop."
        }
        return "Tap to start; tap again to stop."
    }

    private var pushToTalkHotkeyDisplayLabelOverride: String? {
        SettingsDictationHotkeyDisplay.pushToTalkDisplayLabelOverride(
            pushToTalk: viewModel.pushToTalkHotkeyTrigger,
            handsFree: viewModel.hotkeyTrigger
        )
    }

    private var handsFreeHotkeyDisplayLabelOverride: String? {
        SettingsDictationHotkeyDisplay.handsFreeDisplayLabelOverride(
            handsFree: viewModel.hotkeyTrigger,
            pushToTalk: viewModel.pushToTalkHotkeyTrigger
        )
    }

    private var handsFreeHotkeyDefaultLabelOverride: String? {
        SettingsDictationHotkeyDisplay.handsFreeDefaultLabelOverride(
            pushToTalk: viewModel.pushToTalkHotkeyTrigger
        )
    }

    private func modeShortcutRow(
        keys: [String],
        separator: String?,
        verb: String,
        action: String,
        detail: String
    ) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 3) {
                if keys.count == 2, let sep = separator {
                    miniSettingsKeyCap(keys[0])
                    Text(sep)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    miniSettingsKeyCap(keys[1])
                } else {
                    Text(verb)
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(.secondary)
                    miniSettingsKeyCap(keys[0])
                }
            }
            .frame(minWidth: 100, alignment: .leading)

            Text(action)
                .font(DesignSystem.Typography.bodySmall.weight(.medium))

            Spacer()

            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func miniSettingsKeyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignSystem.Colors.cardBackground)
                    .shadow(color: .black.opacity(0.06), radius: 0.5, x: 0, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
            )
    }

    // MARK: - Helpers

    private func aboutRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func buildIdentityReport(_ identity: BuildIdentity) -> String {
        [
            "MacParakeet Build Identity",
            "Version: \(identity.version)",
            "Build: \(identity.buildNumber)",
            "Source: \(identity.buildSource)",
            "Commit: \(identity.gitCommit)",
            "Built: \(identity.buildDateUTC)",
            "Executable: \(identity.executablePath)",
            "Bundle: \(identity.bundlePath)",
        ]
        .joined(separator: "\n")
    }

    @ViewBuilder
    private func permissionPill(granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
            Text(granted ? "Granted" : "Not Granted")
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(granted ? DesignSystem.Colors.successGreen : DesignSystem.Colors.errorRed)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(granted ? DesignSystem.Colors.successGreen.opacity(0.1) : DesignSystem.Colors.errorRed.opacity(0.1))
        )
    }

    @ViewBuilder
    private func modelStatusPill(_ status: SettingsViewModel.LocalModelStatus) -> some View {
        let (icon, text, color): (String, String, Color) = switch status {
        case .unknown:
            ("questionmark.circle.fill", "Unknown", .secondary)
        case .checking:
            ("clock.fill", "Checking", DesignSystem.Colors.warningAmber)
        case .ready:
            ("checkmark.circle.fill", "Ready", DesignSystem.Colors.successGreen)
        case .notLoaded:
            // The model is on disk and will lazy-load on first use; this is a
            // healthy idle state, not an error. Earlier copy ("Not Loaded"
            // with a pause icon) read as broken and prompted users to hit
            // Repair to "fix" something that wasn't actually broken.
            ("checkmark.circle.fill", "Installed", DesignSystem.Colors.successGreen)
        case .notDownloaded:
            ("arrow.down.circle.fill", "Not Downloaded", DesignSystem.Colors.errorRed)
        case .preparing:
            ("gearshape.fill", "Preparing", DesignSystem.Colors.warningAmber)
        case .repairing:
            ("wrench.and.screwdriver.fill", "Repairing", DesignSystem.Colors.warningAmber)
        case .failed:
            ("xmark.circle.fill", "Failed", DesignSystem.Colors.errorRed)
        }

        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    private func modelStatusHelp(_ status: SettingsViewModel.LocalModelStatus) -> String {
        switch status {
        case .unknown:
            "Model status has not been checked yet."
        case .checking:
            "Checking whether the model is available on this Mac."
        case .ready:
            "Model is loaded in memory and ready to use."
        case .notLoaded:
            "Model files are installed locally. The model will load when selected or used."
        case .notDownloaded:
            "Model files are missing and must be downloaded before use."
        case .preparing:
            "Model is being prepared for this Mac."
        case .repairing:
            "Model setup is currently running."
        case .failed:
            "The last model setup attempt failed."
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
