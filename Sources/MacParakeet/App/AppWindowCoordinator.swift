import AppKit
import Sparkle
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppWindowCoordinator: NSObject, NSWindowDelegate {
    private let mainWindowState: MainWindowState
    private let transcriptionViewModel: TranscriptionViewModel
    private let historyViewModel: DictationHistoryViewModel
    private let settingsViewModel: SettingsViewModel
    private let llmSettingsViewModel: LLMSettingsViewModel
    private let chatViewModel: TranscriptChatViewModel
    private let promptResultsViewModel: PromptResultsViewModel
    private let promptsViewModel: PromptsViewModel
    private let transformsViewModel: TransformsViewModel
    private let customWordsViewModel: CustomWordsViewModel
    private let textSnippetsViewModel: TextSnippetsViewModel
    private let vocabularyBackupViewModel: VocabularyBackupViewModel
    private let feedbackViewModel: FeedbackViewModel
    private let discoverViewModel: DiscoverViewModel
    private let libraryViewModel: TranscriptionLibraryViewModel
    private let meetingsWorkspaceViewModel: MeetingsWorkspaceViewModel
    private let meetingPillViewModel: MeetingRecordingPillViewModel
    private let updaterController: SPUStandardUpdaterController
    private let onRecordMeeting: () -> Void
    private let onRecordMeetingFromWorkspace: () -> Void
    private let onPauseToggleMeeting: (() -> Void)?
    private let onHotkeyRecordingStateChanged: (Bool) -> Void
    private let onQuit: () -> Void
    private let isOnboardingVisible: () -> Bool

    private var mainWindow: NSWindow?

    init(
        mainWindowState: MainWindowState,
        transcriptionViewModel: TranscriptionViewModel,
        historyViewModel: DictationHistoryViewModel,
        settingsViewModel: SettingsViewModel,
        llmSettingsViewModel: LLMSettingsViewModel,
        chatViewModel: TranscriptChatViewModel,
        promptResultsViewModel: PromptResultsViewModel,
        promptsViewModel: PromptsViewModel,
        transformsViewModel: TransformsViewModel,
        customWordsViewModel: CustomWordsViewModel,
        textSnippetsViewModel: TextSnippetsViewModel,
        vocabularyBackupViewModel: VocabularyBackupViewModel,
        feedbackViewModel: FeedbackViewModel,
        discoverViewModel: DiscoverViewModel,
        libraryViewModel: TranscriptionLibraryViewModel,
        meetingsWorkspaceViewModel: MeetingsWorkspaceViewModel,
        meetingPillViewModel: MeetingRecordingPillViewModel,
        updaterController: SPUStandardUpdaterController,
        onRecordMeeting: @escaping () -> Void,
        onRecordMeetingFromWorkspace: @escaping () -> Void,
        onPauseToggleMeeting: (() -> Void)? = nil,
        onHotkeyRecordingStateChanged: @escaping (Bool) -> Void,
        onQuit: @escaping () -> Void,
        isOnboardingVisible: @escaping () -> Bool
    ) {
        self.mainWindowState = mainWindowState
        self.transcriptionViewModel = transcriptionViewModel
        self.historyViewModel = historyViewModel
        self.settingsViewModel = settingsViewModel
        self.llmSettingsViewModel = llmSettingsViewModel
        self.chatViewModel = chatViewModel
        self.promptResultsViewModel = promptResultsViewModel
        self.promptsViewModel = promptsViewModel
        self.transformsViewModel = transformsViewModel
        self.customWordsViewModel = customWordsViewModel
        self.textSnippetsViewModel = textSnippetsViewModel
        self.vocabularyBackupViewModel = vocabularyBackupViewModel
        self.feedbackViewModel = feedbackViewModel
        self.discoverViewModel = discoverViewModel
        self.libraryViewModel = libraryViewModel
        self.meetingsWorkspaceViewModel = meetingsWorkspaceViewModel
        self.meetingPillViewModel = meetingPillViewModel
        self.updaterController = updaterController
        self.onRecordMeeting = onRecordMeeting
        self.onRecordMeetingFromWorkspace = onRecordMeetingFromWorkspace
        self.onPauseToggleMeeting = onPauseToggleMeeting
        self.onHotkeyRecordingStateChanged = onHotkeyRecordingStateChanged
        self.onQuit = onQuit
        self.isOnboardingVisible = isOnboardingVisible
    }

    var hasVisiblePrimaryWindow: Bool {
        (mainWindow?.isVisible ?? false) || isOnboardingVisible()
    }

    func openMainWindow() {
        if mainWindow == nil {
            createMainWindow()
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openMainWindowToSettings(tab: SettingsTab? = nil) {
        mainWindowState.navigateToSettings(tab: tab)
        openMainWindow()
    }

    func handleAppReopen() -> Bool {
        if hasVisiblePrimaryWindow {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openMainWindow()
        }
        return true
    }

    func applyActivationPolicyFromSettings() {
        let menuBarOnly = settingsViewModel.menuBarOnlyMode
        let wasMainWindowVisible = mainWindow?.isVisible ?? false
        let mode: NSApplication.ActivationPolicy = menuBarOnly ? .accessory : .regular
        NSApp.setActivationPolicy(mode)

        // macOS hides all windows when switching to .accessory policy.
        // Re-show the main window so the user isn't surprised by it disappearing.
        if menuBarOnly && wasMainWindowVisible {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func makeDockMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open MacParakeet",
            action: #selector(dockOpenMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(dockOpenSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit MacParakeet",
            action: #selector(dockQuit),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func dockOpenMainWindow() {
        openMainWindow()
    }

    @objc private func dockOpenSettings() {
        openMainWindowToSettings()
    }

    @objc private func dockQuit() {
        onQuit()
    }

    private func createMainWindow() {
        let contentView = MainWindowView(
            state: mainWindowState,
            transcriptionViewModel: transcriptionViewModel,
            historyViewModel: historyViewModel,
            settingsViewModel: settingsViewModel,
            llmSettingsViewModel: llmSettingsViewModel,
            chatViewModel: chatViewModel,
            promptResultsViewModel: promptResultsViewModel,
            promptsViewModel: promptsViewModel,
            transformsViewModel: transformsViewModel,
            customWordsViewModel: customWordsViewModel,
            textSnippetsViewModel: textSnippetsViewModel,
            vocabularyBackupViewModel: vocabularyBackupViewModel,
            feedbackViewModel: feedbackViewModel,
            discoverViewModel: discoverViewModel,
            libraryViewModel: libraryViewModel,
            meetingsWorkspaceViewModel: meetingsWorkspaceViewModel,
            meetingPillViewModel: meetingPillViewModel,
            updater: updaterController.updater,
            onRecordMeeting: onRecordMeeting,
            onRecordMeetingFromWorkspace: onRecordMeetingFromWorkspace,
            onPauseToggleMeeting: onPauseToggleMeeting,
            onHotkeyRecordingStateChanged: onHotkeyRecordingStateChanged
        )

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DesignSystem.Layout.sidebarMinWidth + DesignSystem.Layout.contentMinWidth,
                height: DesignSystem.Layout.windowMinHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacParakeet"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.minSize = NSSize(
            width: DesignSystem.Layout.sidebarMinWidth + DesignSystem.Layout.contentMinWidth,
            height: DesignSystem.Layout.windowMinHeight
        )
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        window.isReleasedWhenClosed = false

        mainWindow = window
    }

    func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        showDockIconIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        window.contentView = nil
        mainWindow = nil
        // Delay slightly so macOS finishes closing the window before we check visibility.
        Task { @MainActor [weak self] in
            self?.hideDockIconIfNeeded()
        }
    }

    private func showDockIconIfNeeded() {
        guard settingsViewModel.menuBarOnlyMode else { return }
        NSApp.setActivationPolicy(.regular)
    }

    private func hideDockIconIfNeeded() {
        guard settingsViewModel.menuBarOnlyMode else { return }
        // Only hide if no primary windows are visible.
        guard !hasVisiblePrimaryWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
