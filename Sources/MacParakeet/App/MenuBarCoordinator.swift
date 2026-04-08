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
    private let meetingRecordingActiveProvider: () -> Bool
    private let onOpenMainWindow: () -> Void
    private let onOpenSettings: () -> Void
    private let onToggleMeetingRecording: () -> Void
    private let onQuit: () -> Void
    private let onShowAboutPanel: () -> Void

    private var statusItem: NSStatusItem?
    private var pasteLastMenuItem: NSMenuItem?
    private var recentDictationsMenuItem: NSMenuItem?
    private var recordMeetingMenuItem: NSMenuItem?
    private var hotkeyMenuItem: NSMenuItem?

    init(
        updaterController: SPUStandardUpdaterController,
        transcriptionViewModel: TranscriptionViewModel,
        youtubeInputController: YouTubeInputPanelController,
        environmentProvider: @escaping () -> AppEnvironment?,
        hotkeyMenuTitleProvider: @escaping () -> String,
        meetingHotkeyTriggerProvider: @escaping () -> HotkeyTrigger,
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

        menu.addItem(NSMenuItem.separator())

        let transcribeFileItem = NSMenuItem(
            title: "Transcribe File...",
            action: #selector(transcribeFileFromMenu),
            keyEquivalent: ""
        )
        transcribeFileItem.target = self
        menu.addItem(transcribeFileItem)

        let transcribeYouTubeItem = NSMenuItem(
            title: "Transcribe from YouTube...",
            action: #selector(transcribeFromYouTubeMenu),
            keyEquivalent: ""
        )
        transcribeYouTubeItem.target = self
        menu.addItem(transcribeYouTubeItem)

        let recordMeetingItem = NSMenuItem(
            title: "Record Meeting",
            action: #selector(toggleMeetingRecordingFromMenu),
            keyEquivalent: ""
        )
        recordMeetingItem.target = self
        applyMeetingHotkeyToMenuItem(recordMeetingItem)
        menu.addItem(recordMeetingItem)
        recordMeetingMenuItem = recordMeetingItem

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
            action: #selector(openSettings),
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
        applyMeetingHotkeyToMenuItem(recordMeetingMenuItem)
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

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quitApp() {
        onQuit()
    }

    @objc private func pasteLastDictation() {
        guard let env = environmentProvider() else { return }
        Task {
            guard let dictation = (try? env.dictationRepo.fetchAll(limit: 1))?.first else { return }
            let text = dictation.cleanTranscript ?? dictation.rawTranscript
            await pasteFromMenu(text: text, clipboardService: env.clipboardService)
        }
    }

    @objc private func pasteRecentDictation(_ sender: NSMenuItem) {
        guard let env = environmentProvider(),
              let id = sender.representedObject as? UUID else { return }
        Task {
            guard let dictation = try? env.dictationRepo.fetch(id: id) else { return }
            let text = dictation.cleanTranscript ?? dictation.rawTranscript
            await pasteFromMenu(text: text, clipboardService: env.clipboardService)
        }
    }

    @objc private func transcribeFileFromMenu() {
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

    @objc private func transcribeFromYouTubeMenu() {
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
            return
        }

        let dictations = (try? env.dictationRepo.fetchAll(limit: 5)) ?? []
        pasteLastMenuItem?.isEnabled = !dictations.isEmpty
        rebuildRecentDictationsSubmenu(with: dictations)

        recordMeetingMenuItem?.title = meetingRecordingActiveProvider()
            ? "Stop Meeting Recording"
            : "Record Meeting"
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
            let text = (dictation.cleanTranscript ?? dictation.rawTranscript)
                .replacingOccurrences(of: "\n", with: " ")
            let truncated = text.count > 40 ? String(text.prefix(40)) + "…" : text
            let item = NSMenuItem(
                title: truncated,
                action: #selector(pasteRecentDictation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = dictation.id
            submenu.addItem(item)
        }
        recentItem.submenu = submenu
    }

    private func applyMeetingHotkeyToMenuItem(_ item: NSMenuItem) {
        let trigger = meetingHotkeyTriggerProvider()
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
