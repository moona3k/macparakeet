import AppKit
import Sparkle
import UniformTypeIdentifiers
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class MenuBarCoordinator: NSObject, NSMenuDelegate {
    private let updaterController: SPUStandardUpdaterController
    private let transcriptionViewModel: TranscriptionViewModel
    private let youtubeInputController: YouTubeInputPanelController
    private let environmentProvider: () -> AppEnvironment?
    private let hotkeyMenuTitleProvider: () -> String
    private let meetingHotkeyTriggerProvider: () -> HotkeyTrigger
    private let fileTranscriptionHotkeyTriggerProvider: () -> HotkeyTrigger
    private let youtubeTranscriptionHotkeyTriggerProvider: () -> HotkeyTrigger
    private let meetingRecordingActiveProvider: () -> Bool
    private let onOpenMainWindow: () -> Void
    private let onOpenSettings: () -> Void
    private let onToggleMeetingRecording: () -> Void
    private let onQuit: () -> Void
    private let onShowAboutPanel: () -> Void

    private var statusItem: NSStatusItem?
    private var pasteLastMenuItem: NSMenuItem?
    private var recentDictationsMenuItem: NSMenuItem?
    private var pasteLastTransformMenuItem: NSMenuItem?
    private var recentTransformsMenuItem: NSMenuItem?
    private var recordMeetingMenuItem: NSMenuItem?
    private var transcribeFileMenuItem: NSMenuItem?
    private var transcribeYouTubeMenuItem: NSMenuItem?
    private var hotkeyMenuItem: NSMenuItem?

    init(
        updaterController: SPUStandardUpdaterController,
        transcriptionViewModel: TranscriptionViewModel,
        youtubeInputController: YouTubeInputPanelController,
        environmentProvider: @escaping () -> AppEnvironment?,
        hotkeyMenuTitleProvider: @escaping () -> String,
        meetingHotkeyTriggerProvider: @escaping () -> HotkeyTrigger,
        fileTranscriptionHotkeyTriggerProvider: @escaping () -> HotkeyTrigger,
        youtubeTranscriptionHotkeyTriggerProvider: @escaping () -> HotkeyTrigger,
        meetingRecordingActiveProvider: @escaping () -> Bool,
        onOpenMainWindow: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onToggleMeetingRecording: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onShowAboutPanel: @escaping () -> Void
    ) {
        self.updaterController = updaterController
        self.transcriptionViewModel = transcriptionViewModel
        self.youtubeInputController = youtubeInputController
        self.environmentProvider = environmentProvider
        self.hotkeyMenuTitleProvider = hotkeyMenuTitleProvider
        self.meetingHotkeyTriggerProvider = meetingHotkeyTriggerProvider
        self.fileTranscriptionHotkeyTriggerProvider = fileTranscriptionHotkeyTriggerProvider
        self.youtubeTranscriptionHotkeyTriggerProvider = youtubeTranscriptionHotkeyTriggerProvider
        self.meetingRecordingActiveProvider = meetingRecordingActiveProvider
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenSettings = onOpenSettings
        self.onToggleMeetingRecording = onToggleMeetingRecording
        self.onQuit = onQuit
        self.onShowAboutPanel = onShowAboutPanel
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "About MacParakeet",
            action: #selector(showAboutPanel),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        appMenu.addItem(checkForUpdatesItem)
        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit MacParakeet",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let statusItem,
              let button = statusItem.button else { return }

        button.image = BreathWaveIcon.menuBarIcon(pointSize: 18)

        let dropView = MenuBarDropView(frame: button.bounds)
        dropView.onDrop = { [weak self] url in
            Task { @MainActor in
                self?.handleDroppedFile(url)
            }
        }
        button.addSubview(dropView)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let openItem = NSMenuItem(
            title: "Open MacParakeet",
            action: #selector(openMainWindow),
            keyEquivalent: "o"
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let pasteItem = NSMenuItem(
            title: "Paste Last Dictation",
            action: #selector(pasteLastDictation),
            keyEquivalent: ""
        )
        pasteItem.isEnabled = false
        pasteItem.target = self
        menu.addItem(pasteItem)
        pasteLastMenuItem = pasteItem

        let recentItem = NSMenuItem(
            title: "Recent Dictations",
            action: nil,
            keyEquivalent: ""
        )
        recentItem.submenu = NSMenu()
        recentItem.isHidden = true
        menu.addItem(recentItem)
        recentDictationsMenuItem = recentItem

        let pasteTransformItem = NSMenuItem(
            title: "Paste Last Transform",
            action: #selector(pasteLastTransform),
            keyEquivalent: ""
        )
        pasteTransformItem.isEnabled = false
        pasteTransformItem.target = self
        menu.addItem(pasteTransformItem)
        pasteLastTransformMenuItem = pasteTransformItem

        let recentTransformsItem = NSMenuItem(
            title: "Recent Transforms",
            action: nil,
            keyEquivalent: ""
        )
        recentTransformsItem.submenu = NSMenu()
        recentTransformsItem.isHidden = true
        menu.addItem(recentTransformsItem)
        recentTransformsMenuItem = recentTransformsItem

        menu.addItem(NSMenuItem.separator())

        let transcribeFileItem = NSMenuItem(
            title: "Transcribe File...",
            action: #selector(transcribeFileFromMenu),
            keyEquivalent: ""
        )
        transcribeFileItem.target = self
        applyChordShortcut(fileTranscriptionHotkeyTriggerProvider(), to: transcribeFileItem)
        menu.addItem(transcribeFileItem)
        transcribeFileMenuItem = transcribeFileItem

        let transcribeYouTubeItem = NSMenuItem(
            title: "Transcribe from YouTube...",
            action: #selector(transcribeFromYouTubeMenu),
            keyEquivalent: ""
        )
        transcribeYouTubeItem.target = self
        applyChordShortcut(youtubeTranscriptionHotkeyTriggerProvider(), to: transcribeYouTubeItem)
        menu.addItem(transcribeYouTubeItem)
        transcribeYouTubeMenuItem = transcribeYouTubeItem

        if AppFeatures.meetingRecordingEnabled {
            let recordMeetingItem = NSMenuItem(
                title: "Start Recording",
                action: #selector(toggleMeetingRecordingFromMenu),
                keyEquivalent: ""
            )
            recordMeetingItem.target = self
            applyChordShortcut(meetingHotkeyTriggerProvider(), to: recordMeetingItem)
            menu.addItem(recordMeetingItem)
            recordMeetingMenuItem = recordMeetingItem
        }

        menu.addItem(NSMenuItem.separator())

        let hotkeyItem = NSMenuItem(
            title: hotkeyMenuTitleProvider(),
            action: nil,
            keyEquivalent: ""
        )
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)
        hotkeyMenuItem = hotkeyItem

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        menu.addItem(checkForUpdatesItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit MacParakeet",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func refreshHotkeyTitle() {
        hotkeyMenuItem?.title = hotkeyMenuTitleProvider()
    }

    func refreshMeetingHotkeyShortcut() {
        guard let recordMeetingMenuItem else { return }
        applyChordShortcut(meetingHotkeyTriggerProvider(), to: recordMeetingMenuItem)
    }

    func refreshTranscriptionHotkeyShortcuts() {
        if let transcribeFileMenuItem {
            applyChordShortcut(fileTranscriptionHotkeyTriggerProvider(), to: transcribeFileMenuItem)
        }
        if let transcribeYouTubeMenuItem {
            applyChordShortcut(youtubeTranscriptionHotkeyTriggerProvider(), to: transcribeYouTubeMenuItem)
        }
    }

    /// Entry point for the file-transcription global hotkey. Shares its
    /// implementation with the menu-bar item so both behave identically.
    func invokeTranscribeFileFlow() {
        transcribeFileFlow()
    }

    /// Entry point for the YouTube-transcription global hotkey. Shares its
    /// implementation with the menu-bar item.
    func invokeTranscribeYouTubeFlow() {
        transcribeYouTubeFlow()
    }

    func updateIcon(state: BreathWaveIcon.MenuBarState) {
        statusItem?.button?.image = BreathWaveIcon.menuBarIcon(pointSize: 18, state: state)
    }

    @objc private func showAboutPanel() {
        onShowAboutPanel()
    }

    @objc private func openMainWindow() {
        onOpenMainWindow()
    }

    // Named to avoid matching the macOS 14+ `openSettings:` system action,
    // which would trigger automatic gear SF Symbol decoration on the menu item.
    @objc private func showSettingsWindow() {
        onOpenSettings()
    }

    @objc private func quitApp() {
        onQuit()
    }

    @objc private func pasteLastDictation() {
        guard let env = environmentProvider() else { return }
        Task {
            guard let dictation = (try? env.dictationRepo.fetchAll(limit: 1))?.first else { return }
            // displayText honors the per-row "Undo AI edit" override.
            let text = dictation.displayText
            await pasteFromMenu(text: text, clipboardService: env.clipboardService)
        }
    }

    @objc private func pasteRecentDictation(_ sender: NSMenuItem) {
        guard let env = environmentProvider(),
              let id = sender.representedObject as? UUID else { return }
        Task {
            guard let dictation = try? env.dictationRepo.fetch(id: id) else { return }
            let text = dictation.displayText
            await pasteFromMenu(text: text, clipboardService: env.clipboardService)
        }
    }

    @objc private func pasteLastTransform() {
        guard let env = environmentProvider() else { return }
        Task {
            guard let entry = (try? env.transformHistoryRepo.fetchRecent(limit: 1))?.first else { return }
            await pasteFromMenu(text: entry.outputText, clipboardService: env.clipboardService)
        }
    }

    @objc private func pasteRecentTransform(_ sender: NSMenuItem) {
        guard let env = environmentProvider(),
              let id = sender.representedObject as? UUID else { return }
        Task {
            guard let entry = try? env.transformHistoryRepo.fetch(id: id) else { return }
            await pasteFromMenu(text: entry.outputText, clipboardService: env.clipboardService)
        }
    }

    @objc private func transcribeFileFromMenu() {
        transcribeFileFlow()
    }

    @objc private func transcribeFromYouTubeMenu() {
        transcribeYouTubeFlow()
    }

    private func transcribeFileFlow() {
        guard environmentProvider() != nil else { return }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AudioFileConverter.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }

        if panel.runModal() == .OK, let url = panel.url {
            onOpenMainWindow()
            transcriptionViewModel.transcribeFile(url: url)
            SoundManager.shared.play(.fileDropped)
        }
    }

    private func transcribeYouTubeFlow() {
        guard environmentProvider() != nil else { return }
        youtubeInputController.show()
    }

    @objc private func toggleMeetingRecordingFromMenu() {
        onToggleMeetingRecording()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let env = environmentProvider() else {
            pasteLastMenuItem?.isEnabled = false
            recentDictationsMenuItem?.isHidden = true
            pasteLastTransformMenuItem?.isEnabled = false
            recentTransformsMenuItem?.isHidden = true
            return
        }

        let dictations = (try? env.dictationRepo.fetchAll(limit: 5)) ?? []
        pasteLastMenuItem?.isEnabled = !dictations.isEmpty
        rebuildRecentDictationsSubmenu(with: dictations)

        let transforms = (try? env.transformHistoryRepo.fetchRecent(limit: 5)) ?? []
        pasteLastTransformMenuItem?.isEnabled = !transforms.isEmpty
        rebuildRecentTransformsSubmenu(with: transforms)

        recordMeetingMenuItem?.title = meetingRecordingActiveProvider()
            ? "Stop Recording"
            : "Start Recording"
    }

    private func handleDroppedFile(_ url: URL) {
        onOpenMainWindow()
        transcriptionViewModel.transcribeFile(url: url)
        SoundManager.shared.play(.fileDropped)
    }

    /// Resign menu-bar focus, wait for the target app to regain focus, then paste.
    private func pasteFromMenu(text: String, clipboardService: ClipboardServiceProtocol) async {
        NSApp.deactivate()
        try? await Task.sleep(for: .milliseconds(200))
        do {
            try await clipboardService.pasteText(text)
        } catch {
            await clipboardService.copyToClipboard(text)
        }
    }

    private func rebuildRecentDictationsSubmenu(with dictations: [Dictation]) {
        guard let recentItem = recentDictationsMenuItem else { return }
        recentItem.isHidden = dictations.isEmpty

        let submenu = NSMenu()
        for dictation in dictations {
            let item = NSMenuItem(
                title: MenuPreviewFormatter.dictationTitle(text: dictation.displayText),
                action: #selector(pasteRecentDictation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = dictation.id
            submenu.addItem(item)
        }
        recentItem.submenu = submenu
    }

    private func rebuildRecentTransformsSubmenu(with entries: [TransformHistoryEntry]) {
        guard let recentItem = recentTransformsMenuItem else { return }
        recentItem.isHidden = entries.isEmpty

        let submenu = NSMenu()
        for entry in entries {
            let item = NSMenuItem(
                title: MenuPreviewFormatter.transformTitle(outputText: entry.outputText),
                action: #selector(pasteRecentTransform(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            submenu.addItem(item)
        }
        recentItem.submenu = submenu
    }

    /// Apply a chord trigger's visual shortcut to a menu item. Non-chord or
    /// disabled triggers clear the key equivalent.
    ///
    /// Note: this only paints the visual hint. The actual hotkey is handled by
    /// `GlobalShortcutManager` in the app layer, so keyEquivalent matches
    /// aren't required for the shortcut to fire while the menu is closed.
    private func applyChordShortcut(_ trigger: HotkeyTrigger, to item: NSMenuItem) {
        guard trigger.kind == .chord, let code = trigger.keyCode else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }

        let keyName = KeyCodeNames.name(for: code).shortSymbol
        item.keyEquivalent = keyName.lowercased()

        var mask: NSEvent.ModifierFlags = []
        for modifier in trigger.chordModifiers ?? [] {
            switch modifier {
            case "command": mask.insert(.command)
            case "shift": mask.insert(.shift)
            case "control": mask.insert(.control)
            case "option": mask.insert(.option)
            default: break
            }
        }
        item.keyEquivalentModifierMask = mask
    }
}
