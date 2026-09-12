import AppKit
import Sparkle
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Tracks which `NSWindow` instance is the current main window, isolated from
/// `AppWindowCoordinator`'s large view-model graph so the close/reopen
/// bookkeeping can be unit tested directly.
///
/// AppKit is still mid-teardown of a closing window when `windowWillClose(_:)`
/// runs, so this defers the actual `contentView` release until after that
/// callback returns.
@MainActor
struct MainWindowLifecycle {
    private(set) var window: NSWindow?

    var hasWindow: Bool { window != nil }

    mutating func opened(_ window: NSWindow) {
        self.window = window
    }

    /// Detaches `closingWindow` if it is still the tracked window, so an
    /// immediate reopen can create a fresh instance, then defers that
    /// window's content teardown until after AppKit finishes closing it.
    /// Returns the detached window, or `nil` if `closingWindow` is already
    /// stale (e.g. a late/duplicate notification for a window a prior close
    /// already detached, possibly superseded by a replacement) — in which
    /// case no teardown is scheduled and the replacement is left untouched.
    @discardableResult
    mutating func windowWillClose(_ closingWindow: NSWindow) -> NSWindow? {
        guard closingWindow === window else { return nil }
        window = nil
        // Clearing contentView here would tear down the NSHostingView while
        // AppKit is still walking through this window's own close teardown.
        // Defer that release until after AppKit finishes. `closingWindow` is
        // this exact window instance, not a re-read of `window` (which may
        // already track a replacement from an immediate reopen), so only
        // this window's content is ever released.
        DispatchQueue.main.async {
            closingWindow.contentView = nil
        }
        return closingWindow
    }
}

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
    private let shareManagementViewModel: ShareManagementViewModel?
    private let updaterController: SPUStandardUpdaterController
    private let onRecordMeeting: () -> Void
    private let onRecordMeetingFromWorkspace: () -> Void
    private let onPauseToggleMeeting: (() -> Void)?
    private let onHotkeyRecordingStateChanged: (Bool) -> Void
    private let onQuit: () -> Void
    private let isOnboardingVisible: () -> Bool

    private var mainWindowLifecycle = MainWindowLifecycle()
    private var mainWindow: NSWindow? { mainWindowLifecycle.window }

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
        shareManagementViewModel: ShareManagementViewModel? = nil,
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
        self.shareManagementViewModel = shareManagementViewModel
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
        NSApp.setActivationPolicy(Self.activationPolicy(
            menuBarOnlyMode: settingsViewModel.menuBarOnlyMode,
            hasVisiblePrimaryWindow: hasVisiblePrimaryWindow
        ))
    }

    static func activationPolicy(
        menuBarOnlyMode: Bool,
        hasVisiblePrimaryWindow: Bool
    ) -> NSApplication.ActivationPolicy {
        menuBarOnlyMode && !hasVisiblePrimaryWindow ? .accessory : .regular
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
            shareManagementViewModel: shareManagementViewModel,
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

        mainWindowLifecycle.opened(window)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        showDockIconIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            mainWindowLifecycle.windowWillClose(window) != nil
        else { return }
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
