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
    private let dictationCaptureActiveProvider: () -> Bool
    private let onOpenMainWindow: () -> Void
    private let onOpenSettings: () -> Void
    private let onNavigate: (SidebarItem) -> Void
    private let onNewTranscription: () -> Void
    private let onStartDictation: () -> Void
    private let onToggleMeetingRecording: () -> Void
    private let onCreateTransform: () -> Void
    private let onQuit: () -> Void
    private let onShowAboutPanel: () -> Void

    private var statusItem: NSStatusItem?
    private var newTranscriptionMenuItem: NSMenuItem?
    private var startDictationMenuItem: NSMenuItem?
    private var createTransformMenuItem: NSMenuItem?
    private var pasteLastMenuItem: NSMenuItem?
    private var recentDictationsMenuItem: NSMenuItem?
    private var pasteLastTransformMenuItem: NSMenuItem?
    private var recentTransformsMenuItem: NSMenuItem?
    private var recordMeetingMenuItems: [NSMenuItem] = []
    private var transcribeFileMenuItems: [NSMenuItem] = []
    private var transcribeYouTubeMenuItems: [NSMenuItem] = []
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
        dictationCaptureActiveProvider: @escaping () -> Bool,
        onOpenMainWindow: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onNavigate: @escaping (SidebarItem) -> Void,
        onNewTranscription: @escaping () -> Void,
        onStartDictation: @escaping () -> Void,
        onToggleMeetingRecording: @escaping () -> Void,
        onCreateTransform: @escaping () -> Void,
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
        self.dictationCaptureActiveProvider = dictationCaptureActiveProvider
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenSettings = onOpenSettings
        self.onNavigate = onNavigate
        self.onNewTranscription = onNewTranscription
        self.onStartDictation = onStartDictation
        self.onToggleMeetingRecording = onToggleMeetingRecording
        self.onCreateTransform = onCreateTransform
        self.onQuit = onQuit
        self.onShowAboutPanel = onShowAboutPanel
    }

    private static var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "MacParakeet"
    }

    private func makeMenuItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = Self.appDisplayName

        let aboutItem = NSMenuItem(
            title: "About \(appName)",
            action: #selector(showAboutPanel),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        appMenu.addItem(checkForUpdatesItem)
        appMenu.addItem(NSMenuItem.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(
            title: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let captureMenuItem = NSMenuItem()
        let captureMenu = NSMenu(title: "Capture")
        captureMenu.autoenablesItems = false
        captureMenu.delegate = self
        let newTranscriptionItem = makeMenuItem(
            title: "New Transcription",
            action: #selector(newTranscription),
            key: "n"
        )
        captureMenu.addItem(newTranscriptionItem)
        newTranscriptionMenuItem = newTranscriptionItem
        let startDictationItem = makeMenuItem(
            title: "Start Dictation",
            action: #selector(startDictationFromMenu),
            key: ""
        )
        captureMenu.addItem(startDictationItem)
        startDictationMenuItem = startDictationItem
        captureMenu.addItem(NSMenuItem.separator())
        let fileTranscriptionItem = makeMenuItem(
            title: "Transcribe File...",
            action: #selector(transcribeFileFromMenu),
            key: ""
        )
        applyChordShortcut(fileTranscriptionHotkeyTriggerProvider(), to: fileTranscriptionItem)
        transcribeFileMenuItems.append(fileTranscriptionItem)
        captureMenu.addItem(fileTranscriptionItem)
        let youtubeItem = makeMenuItem(
            title: "Transcribe Video...",
            action: #selector(transcribeFromYouTubeMenu),
            key: ""
        )
        applyChordShortcut(youtubeTranscriptionHotkeyTriggerProvider(), to: youtubeItem)
        transcribeYouTubeMenuItems.append(youtubeItem)
        captureMenu.addItem(youtubeItem)
        if AppFeatures.meetingRecordingEnabled {
            let recordMeetingItem = makeMenuItem(
                title: "Start Recording",
                action: #selector(toggleMeetingRecordingFromMenu),
                key: ""
            )
            applyChordShortcut(meetingHotkeyTriggerProvider(), to: recordMeetingItem)
            captureMenu.addItem(recordMeetingItem)
            recordMeetingMenuItems.append(recordMeetingItem)
        }
        if AppFeatures.transformsEnabled {
            captureMenu.addItem(NSMenuItem.separator())
            let createTransformItem = makeMenuItem(
                title: "New Transform",
                action: #selector(createTransformFromMenu),
                key: ""
            )
            captureMenu.addItem(createTransformItem)
            createTransformMenuItem = createTransformItem
        }
        captureMenuItem.submenu = captureMenu
        mainMenu.addItem(captureMenuItem)

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

        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(makeMenuItem(title: "Transcribe", action: #selector(showTranscribe), key: ""))
        goMenu.addItem(makeMenuItem(title: "Library", action: #selector(showLibrary), key: ""))
        goMenu.addItem(makeMenuItem(title: "Dictations", action: #selector(showDictations), key: ""))
        if AppFeatures.meetingRecordingEnabled {
            goMenu.addItem(makeMenuItem(title: "Meetings", action: #selector(showMeetings), key: ""))
        }
        goMenu.addItem(NSMenuItem.separator())
        goMenu.addItem(makeMenuItem(title: "Vocabulary", action: #selector(showVocabulary), key: ""))
        if AppFeatures.transformsEnabled {
            goMenu.addItem(makeMenuItem(title: "Transforms", action: #selector(showTransforms), key: ""))
        }
        goMenu.addItem(makeMenuItem(title: "Feedback", action: #selector(showFeedback), key: ""))
        goMenu.addItem(makeMenuItem(title: "Settings...", action: #selector(showSettingsWindow), key: ""))
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowMenu.addItem(NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(makeMenuItem(title: "Show \(appName)", action: #selector(openMainWindow), key: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(makeMenuItem(title: "\(appName) Help", action: #selector(openHelp), key: ""))
        helpMenu.addItem(makeMenuItem(title: "View on GitHub", action: #selector(openGitHub), key: ""))
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let statusItem,
              let button = statusItem.button else { return }

        button.image = BreathWaveIcon.menuBarIcon(pointSize: 18)

        let dropView = MenuBarDropView(frame: button.bounds)
        dropView.onDrop = { [weak self] urls in
            Task { @MainActor in
                self?.handleDroppedFiles(urls)
            }
        }
        button.addSubview(dropView)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let appName = Self.appDisplayName

        let openItem = NSMenuItem(
            title: "Open \(appName)",
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

        if AppFeatures.transformsEnabled {
            let pasteTransformItem = NSMenuItem(
                title: "Paste Last Transform",
                action: #selector(pasteLastTransform),
                keyEquivalent: ""
            )
            pasteTransformItem.isEnabled = false
            pasteTransformItem.isHidden = true
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
        }

        menu.addItem(NSMenuItem.separator())

        let transcribeFileItem = NSMenuItem(
            title: "Transcribe File...",
            action: #selector(transcribeFileFromMenu),
            keyEquivalent: ""
        )
        transcribeFileItem.target = self
        applyChordShortcut(fileTranscriptionHotkeyTriggerProvider(), to: transcribeFileItem)
        menu.addItem(transcribeFileItem)
        transcribeFileMenuItems.append(transcribeFileItem)

        let transcribeYouTubeItem = NSMenuItem(
            title: "Transcribe Video...",
            action: #selector(transcribeFromYouTubeMenu),
            keyEquivalent: ""
        )
        transcribeYouTubeItem.target = self
        applyChordShortcut(youtubeTranscriptionHotkeyTriggerProvider(), to: transcribeYouTubeItem)
        menu.addItem(transcribeYouTubeItem)
        transcribeYouTubeMenuItems.append(transcribeYouTubeItem)

        if AppFeatures.meetingRecordingEnabled {
            let recordMeetingItem = NSMenuItem(
                title: "Start Recording",
                action: #selector(toggleMeetingRecordingFromMenu),
                keyEquivalent: ""
            )
            recordMeetingItem.target = self
            applyChordShortcut(meetingHotkeyTriggerProvider(), to: recordMeetingItem)
            menu.addItem(recordMeetingItem)
            recordMeetingMenuItems.append(recordMeetingItem)
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
            title: "Quit \(appName)",
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
        recordMeetingMenuItems.forEach { applyChordShortcut(meetingHotkeyTriggerProvider(), to: $0) }
    }

    func refreshTranscriptionHotkeyShortcuts() {
        transcribeFileMenuItems.forEach { applyChordShortcut(fileTranscriptionHotkeyTriggerProvider(), to: $0) }
        transcribeYouTubeMenuItems.forEach { applyChordShortcut(youtubeTranscriptionHotkeyTriggerProvider(), to: $0) }
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

    @objc private func newTranscription() {
        onNewTranscription()
        onOpenMainWindow()
    }

    // Named to avoid matching the macOS 14+ `openSettings:` system action,
    // which would trigger automatic gear SF Symbol decoration on the menu item.
    @objc private func showSettingsWindow() {
        onOpenSettings()
    }

    @objc private func showTranscribe() {
        navigate(to: .transcribe)
    }

    @objc private func showMeetings() {
        navigate(to: .meetings)
    }

    @objc private func showLibrary() {
        navigate(to: .library)
    }

    @objc private func showDictations() {
        navigate(to: .dictations)
    }

    @objc private func showVocabulary() {
        navigate(to: .vocabulary)
    }

    @objc private func showTransforms() {
        navigate(to: .transforms)
    }

    @objc private func showFeedback() {
        navigate(to: .feedback)
    }

    @objc private func startDictationFromMenu() {
        onStartDictation()
    }

    @objc private func createTransformFromMenu() {
        onCreateTransform()
        onOpenMainWindow()
    }

    @objc private func openHelp() {
        openExternalURL("https://macparakeet.com")
    }

    @objc private func openGitHub() {
        openExternalURL("https://github.com/moona3k/macparakeet")
    }

    @objc private func quitApp() {
        onQuit()
    }

    private func navigate(to item: SidebarItem) {
        onNavigate(item)
        onOpenMainWindow()
    }

    private func openExternalURL(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose one or more audio/video files, or a folder, to transcribe."
        panel.allowedContentTypes = AudioFileConverter.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            onOpenMainWindow()
            transcriptionViewModel.transcribeFiles(urls: panel.urls)
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
        let environmentReady = environmentProvider() != nil
        newTranscriptionMenuItem?.isEnabled = environmentReady
        startDictationMenuItem?.isEnabled = environmentReady && !dictationCaptureActiveProvider()
        createTransformMenuItem?.isEnabled = environmentReady
        transcribeFileMenuItems.forEach { $0.isEnabled = environmentReady }
        transcribeYouTubeMenuItems.forEach { $0.isEnabled = environmentReady }
        recordMeetingMenuItems.forEach {
            $0.isEnabled = environmentReady
            $0.title = meetingRecordingActiveProvider()
                ? "Stop Recording"
                : "Start Recording"
        }

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
        pasteLastTransformMenuItem?.isHidden = transforms.isEmpty
        rebuildRecentTransformsSubmenu(with: transforms)

    }

    private func handleDroppedFiles(_ urls: [URL]) {
        onOpenMainWindow()
        // Route through the guarded batch entry point: it expands folders,
        // chooses single vs. batch, and no-ops while a transcription/batch is
        // already running (so an icon drop can't corrupt an active batch).
        if transcriptionViewModel.transcribeFiles(urls: urls) {
            SoundManager.shared.play(.fileDropped)
        }
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
