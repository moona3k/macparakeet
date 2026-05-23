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

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var llmSettingsViewModel: LLMSettingsViewModel
    let updater: SPUUpdater
    let transformHotkeys: [Prompt]
    let requestedTab: SettingsTab?
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

    init(
        viewModel: SettingsViewModel,
        llmSettingsViewModel: LLMSettingsViewModel,
        updater: SPUUpdater,
        transformHotkeys: [Prompt] = [],
        requestedTab: SettingsTab? = nil,
        requestedTabRevision: Int = 0,
        onRequestedTabConsumed: @escaping () -> Void = {},
        onHotkeyRecordingStateChanged: @escaping (Bool) -> Void
    ) {
        self.viewModel = viewModel
        self.llmSettingsViewModel = llmSettingsViewModel
        self.updater = updater
        self.transformHotkeys = transformHotkeys
        self.requestedTab = requestedTab
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
                    case .modes:
                        modesTabContent
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
            if requestedTab != nil {
                onRequestedTabConsumed()
            }
        }
        .onChange(of: requestedTabRevision) { _, _ in
            if let requestedTab {
                rootViewModel.open(tab: requestedTab)
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

        var modesStatuses: [SettingsCardStatus?] = [
            viewModel.microphoneGranted
                ? SettingsCardStatus(.ok, label: "Granted")
                : SettingsCardStatus(.required, label: "Permission required")
        ]
        if AppFeatures.meetingRecordingEnabled {
            modesStatuses.append(meetingRecordingCardStatus)
        }
        if let badge = Self.attentionBadge(for: modesStatuses) {
            badges[.modes] = badge
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
        pendingScrollTarget = entry.cardAnchor
        rootViewModel.activeTab = entry.tab
        rootViewModel.clearSearch()
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

    /// Modes tab — daily-ops config for the three product modes, plus the
    /// Audio Input prerequisite that gates them. The legacy `headerCard`
    /// "Workspace Controls" was eliminated (its stat chips are redundant
    /// with Storage / Permissions / per-mode chips). The legacy `generalCard`
    /// was split: "Show idle pill" lives on the Dictation card now;
    /// Launch at Login + Menu Bar Only moved to the System Startup card.
    /// The Calendar card was folded into Meeting Recording.
    private var modesTabContent: some View {
        scrollableTabBody {
            audioInputCard.id("audio.input")
            dictationCard.id("dictation")
            transcriptionCard.id("transcription")
            if AppFeatures.meetingRecordingEnabled {
                meetingRecordingCard.id("meeting")
            }
        }
    }

    /// Engine tab — speech recognition stack, decomposed into three cards
    /// so each surface owns one decision the user makes:
    ///
    /// 1. `engineSelectorCard` — which engine? (Parakeet vs Whisper)
    /// 2. `engineLanguageCard` — which language? (Whisper only — Parakeet
    ///    auto-detects from its 25 supported European languages)
    /// 3. `enginesModelsCard` — what's the local model state?
    ///
    /// Sub-VM split (`EngineSettingsViewModel`) lands in a later commit;
    /// the cards keep reading from `viewModel` for now.
    private var engineTabContent: some View {
        scrollableTabBody {
            engineSelectorCard.id("engine.selector")
            engineLanguageCard.id("engine.language")
            enginesModelsCard.id("engine.models")
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

    // MARK: - Audio Input

    private var audioInputCard: some View {
        SettingsCard(
            title: "Audio Input",
            subtitle: "Choose the microphone used for dictation and meetings.",
            icon: "mic",
            status: viewModel.microphoneGranted
                ? SettingsCardStatus(.ok, label: "Granted")
                : SettingsCardStatus(.required, label: "Permission required")
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Microphone",
                        detail: viewModel.selectedMicrophoneStatusText
                    )
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
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

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
                    microphoneTestStatus
                    Spacer(minLength: DesignSystem.Spacing.md)
                    Button {
                        switch viewModel.microphoneTestState {
                        case .testing:
                            viewModel.cancelMicrophoneTest()
                        default:
                            viewModel.testSelectedMicrophone()
                        }
                    } label: {
                        Label(
                            viewModel.microphoneTestState == .testing ? "Stop Test" : "Test Input",
                            systemImage: viewModel.microphoneTestState == .testing ? "stop.fill" : "waveform"
                        )
                    }
                    .parakeetAction(.primaryProminent)
                    .disabled(!viewModel.microphoneGranted && viewModel.microphoneTestState != .testing)
                }
            }
        }
    }

    private var microphoneTestStatus: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            microphoneLevelMeter(level: viewModel.microphoneTestLevel)
            VStack(alignment: .leading, spacing: 2) {
                Text(microphoneTestTitle)
                    .font(DesignSystem.Typography.body)
                Text(microphoneTestDetail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(microphoneTestDetailColor)
                    .lineLimit(2)
            }
        }
    }

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

    private var dictationShortcutsAreCombined: Bool {
        let handsFree = viewModel.hotkeyTrigger
        let pushToTalk = viewModel.pushToTalkHotkeyTrigger
        return !handsFree.isDisabled && !pushToTalk.isDisabled && handsFree == pushToTalk
    }

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
                        detail: dictationShortcutsAreCombined
                            ? "Double tap to start; tap once to stop."
                            : "Tap to start; tap again to stop."
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorderView(
                            trigger: $viewModel.hotkeyTrigger,
                            defaultTrigger: .defaultDictation,
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

                // Relocated from the legacy `generalCard` during the IA
                // refactor. The idle pill *is* the dictation summon button,
                // so it belongs alongside the dictation hotkey, not in the
                // OS-integration startup section.
                settingsToggleRow(
                    title: "Show dictation pill at all times",
                    detail: "When off, the pill hides until you use a dictation shortcut.",
                    isOn: $viewModel.showIdlePill
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
            subtitle: "Options for file and YouTube transcription.",
            icon: "doc.text"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                transcriptionHotkeyRow(
                    title: "File transcription hotkey",
                    detail: "Opens the file picker from anywhere on macOS.",
                    trigger: $viewModel.fileTranscriptionHotkeyTrigger,
                    otherTranscriptionTrigger: viewModel.youtubeTranscriptionHotkeyTrigger,
                    otherTranscriptionName: "YouTube transcription"
                )

                Divider()

                transcriptionHotkeyRow(
                    title: "YouTube transcription hotkey",
                    detail: "Opens the YouTube URL panel from anywhere on macOS.",
                    trigger: $viewModel.youtubeTranscriptionHotkeyTrigger,
                    otherTranscriptionTrigger: viewModel.fileTranscriptionHotkeyTrigger,
                    otherTranscriptionName: "file transcription"
                )

                Divider()

                HStack(alignment: .center) {
                    rowText(
                        title: "YouTube audio quality",
                        detail: viewModel.youtubeAudioQuality.detail
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    Picker("YouTube audio quality", selection: $viewModel.youtubeAudioQuality) {
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
        if candidate != viewModel.pushToTalkHotkeyTrigger,
           candidate.overlaps(with: viewModel.pushToTalkHotkeyTrigger) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "push to talk",
                trigger: viewModel.pushToTalkHotkeyTrigger
            ))
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
                conflictingWith: "YouTube transcription",
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
        if candidate != viewModel.hotkeyTrigger,
           candidate.overlaps(with: viewModel.hotkeyTrigger) {
            return .blocked(SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "hands-free mode",
                trigger: viewModel.hotkeyTrigger
            ))
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
                conflictingWith: "YouTube transcription",
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
                conflictingWith: "YouTube transcription",
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
        if trigger != viewModel.pushToTalkHotkeyTrigger,
           trigger.overlaps(with: viewModel.pushToTalkHotkeyTrigger) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "push to talk",
                trigger: viewModel.pushToTalkHotkeyTrigger
            )
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
                conflictingWith: "YouTube transcription",
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
        if trigger != viewModel.hotkeyTrigger,
           trigger.overlaps(with: viewModel.hotkeyTrigger) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: "hands-free mode",
                trigger: viewModel.hotkeyTrigger
            )
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
                conflictingWith: "YouTube transcription",
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
                conflictingWith: "YouTube transcription",
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
                    title: "Keep downloaded YouTube audio",
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
                        title: "YouTube Downloads",
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
                        title: "Downloaded YouTube audio",
                        detail: "Saved audio files only. Transcriptions stay; audio detaches.",
                        action: ResetDestructiveAction(
                            buttonTitle: "Clear…",
                            accessibilityLabel: "Clear downloaded YouTube audio",
                            confirmationTitle: "Clear Downloaded YouTube Audio?",
                            confirmationMessage: "This will delete all downloaded YouTube audio files and detach them from existing transcriptions. This cannot be undone.",
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

                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    EngineOptionTile(
                        icon: "bolt.fill",
                        name: "Parakeet",
                        tagline: "Fastest local engine",
                        strengths: [
                            "English + 24 European languages",
                            "155× realtime on Apple Silicon",
                            "Runs on the Neural Engine"
                        ],
                        helpText: "Best for English and other European languages including Spanish, French, German, and Italian. Runs on the Neural Engine for the lowest latency on Apple Silicon.",
                        modelStatus: displayedParakeetModelStatus,
                        isSelected: viewModel.speechEnginePreference == .parakeet,
                        isBusy: viewModel.speechEngineSwitching,
                        unavailableReason: engineSwitchUnavailableReason(for: .parakeet),
                        onSelect: { selectEngine(.parakeet) }
                    )

                    EngineOptionTile(
                        icon: "globe",
                        name: "Whisper",
                        tagline: "Multilingual coverage",
                        strengths: [
                            "Korean, Japanese, Chinese, Thai +95 more",
                            "Auto language detection",
                            "Whisper Large v3 Turbo (632 MB)"
                        ],
                        helpText: "Best for languages outside Parakeet's coverage. Adds Korean, Japanese, Chinese, Thai, Hindi, Arabic, Vietnamese, and 80+ more — any language Whisper supports.",
                        modelStatus: displayedWhisperModelStatus,
                        isSelected: viewModel.speechEnginePreference == .whisper,
                        isBusy: viewModel.speechEngineSwitching,
                        unavailableReason: engineSwitchUnavailableReason(for: .whisper),
                        needsFirstOptimize: displayedWhisperModelStatus == .notLoaded
                            && !viewModel.whisperHasBeenOptimized,
                        onSelect: { handleWhisperTileTap() }
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
                    overflowAction: displayedParakeetModelStatus == .preparing ? nil : parakeetOverflowAction
                )

                Divider()

                modelStatusRow(
                    title: "Whisper",
                    detail: displayedWhisperModelStatusDetail,
                    status: displayedWhisperModelStatus,
                    isWorking: viewModel.whisperDownloading,
                    actionsDisabled: viewModel.speechEngineSwitching,
                    primaryAction: displayedWhisperModelStatus == .preparing ? nil : whisperPrimaryAction,
                    overflowAction: displayedWhisperModelStatus == .preparing ? nil : whisperOverflowAction
                )
            }
        }
    }

    private var engineSelectorCardStatus: SettingsCardStatus? {
        if viewModel.speechEngineSwitching {
            let target = currentSpeechEngineSwitchTarget
            let label = target == .whisper ? "Preparing Whisper" : "Switching to \(target.displayName)"
            return SettingsCardStatus(.recommended, label: label)
        }
        if viewModel.speechEngineError != nil {
            return SettingsCardStatus(.required, label: "Action needed")
        }
        return nil
    }

    private var speechEngineSwitchBannerState: (title: String, detail: String)? {
        guard viewModel.speechEngineSwitching else { return nil }
        let target = currentSpeechEngineSwitchTarget
        let phase = viewModel.speechEngineSwitchDetail ?? "Preparing speech engine..."
        let title = target == .whisper ? "Preparing Whisper" : "Switching to \(target.displayName)"
        return (
            title,
            "\(phase) Dictation, file transcription, and meetings pause until this finishes."
        )
    }

    private var enginesModelsCardStatus: SettingsCardStatus? {
        SettingsStatusRules.localModelsCardStatus(
            parakeet: displayedParakeetModelStatus,
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
        return viewModel.speechEngineSwitchDetail ?? "Loading Parakeet model on Neural Engine..."
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

    /// Routes a tile click through `speechEnginePreference`. The VM's setter
    /// validates (e.g. would revert if Whisper isn't downloaded), but we
    /// pre-empt that case in `handleWhisperTileTap` so the user never sees
    /// the briefly-selected-then-reverted state.
    private func selectEngine(_ engine: SpeechEnginePreference) {
        guard viewModel.speechEnginePreference != engine,
              !viewModel.speechEngineSwitching else { return }
        Task { @MainActor in
            let availability = await viewModel.refreshSpeechEngineSwitchAvailabilityNow()
            guard availability == .available else {
                viewModel.speechEngineError = SettingsViewModel.speechEngineSwitchUnavailableMessage(for: availability)
                return
            }
            withAnimation(DesignSystem.Animation.contentSwap) {
                viewModel.speechEnginePreference = engine
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

    private var parakeetOverflowAction: ModelRowAction? {
        switch viewModel.parakeetStatus {
        case .ready, .notLoaded:
            return ModelRowAction(
                label: "Repair…",
                isProminent: false,
                help: "Re-validate the Parakeet files and load the model again."
            ) {
                viewModel.repairParakeetModel()
            }
        default:
            return nil
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

    private var whisperOverflowAction: ModelRowAction? {
        switch viewModel.whisperModelStatus {
        case .ready, .notLoaded:
            // Symmetric with Parakeet's "Repair…" — both engines surface the
            // same affordance to the user. Underneath, Parakeet re-runs warmup
            // (which downloads if files are missing); Whisper re-runs the
            // download (no-op via HuggingFace cache when files are intact).
            // The user shouldn't have to reason about that asymmetry.
            return ModelRowAction(
                label: "Repair…",
                isProminent: false,
                help: "Re-check the Whisper files and re-download any missing model assets."
            ) {
                viewModel.downloadWhisperModel()
            }
        default:
            return nil
        }
    }

    fileprivate struct ModelRowAction {
        let label: String
        let isProminent: Bool
        let help: String?
        let run: () -> Void

        init(label: String, isProminent: Bool, help: String? = nil, run: @escaping () -> Void) {
            self.label = label
            self.isProminent = isProminent
            self.help = help
            self.run = run
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
        isOn: Binding<Bool>
    ) -> some View {
        SettingsToggleRow(title: title, detail: detail, isOn: isOn)
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
        overflowAction: ModelRowAction?
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
                    } else if let overflow = overflowAction,
                              !actionsDisabled,
                              !isWorking,
                              status != .checking,
                              status != .repairing,
                              status != .preparing {
                        Menu {
                            Button(overflow.label, action: overflow.run)
                                .help(overflow.help ?? overflow.label)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 22, height: 22)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(overflow.help ?? "More actions")
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
                    verb: dictationShortcutsAreCombined ? "Double tap" : "Tap",
                    action: "Hands-free mode",
                    detail: dictationShortcutsAreCombined ? "Tap once to stop" : "Tap again to stop"
                )
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
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
