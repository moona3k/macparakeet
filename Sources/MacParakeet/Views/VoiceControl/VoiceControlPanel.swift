import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct VoiceControlPanelView: View {
    @Bindable var model: VoiceControlViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: model.microphoneOn ? "mic.fill" : "mic.slash")
                        .accessibilityLabel(model.microphoneOn ? "Microphone on" : "Microphone off")
                    Text(model.literalMode ? "Voice Control · Literal" : "Voice Control").font(.headline)
                    Spacer()
                    Text(model.microphoneOn ? "Listening" : "Mic off").font(.caption).foregroundStyle(.secondary)
                    Button("Close", systemImage: "xmark", action: { model.onEnd?() })
                        .labelStyle(.iconOnly).parakeetAction(.subtle)
                }
                if model.needsSetup {
                    Text("Speak naturally. Act on your Mac.").font(.title2.bold())
                    Text(
                        "Speech recognition stays on this Mac. Jev receives your command and a limited description of visible text and controls in the current app. Password fields are excluded. Cloud control is optional and separate from ordinary dictation."
                    )
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("Controls your current app and browser through macOS Accessibility. Coverage depends on the app.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("TypeSafe / Jev API key", text: $model.keyInput)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Allow commands and app context to be sent to Jev", isOn: $model.consent)
                        .font(.callout)
                        .onChange(of: model.consent) { _, enabled in if !enabled { model.onRevokeConsent?() } }
                    Toggle(
                        "Allow selected text to be sent to my configured writing provider", isOn: $model.writingConsent
                    )
                    .font(.callout)
                    .onChange(of: model.writingConsent) { _, enabled in if !enabled { model.onRevokeWritingConsent?() }
                    }
                    Toggle(
                        "Read on-screen text with Vision (needs Screen Recording; stays on this Mac)",
                        isOn: $model.screenText
                    )
                    .font(.callout)
                    .onChange(of: model.screenText) { _, enabled in model.onScreenTextChanged?(enabled) }
                    HotkeyRecorderView(
                        trigger: $model.holdTrigger,
                        defaultTrigger: VoiceControlCoordinator.holdTrigger,
                        additionalValidation: model.validateShortcut,
                        onRecordingStateChanged: model.onShortcutRecording)
                    Button("Save and enable", action: { model.onSaveSetup?() })
                        .parakeetAction(.primaryProminent).disabled(!model.consent)
                    Button("Disable and forget API key", role: .destructive, action: { model.onDisable?() })
                        .parakeetAction(.subtle)
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                    Text("Your API key is stored in macOS Keychain. No microphone opens until you start listening.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if !model.partialTranscript.isEmpty {
                        Text(model.partialTranscript).foregroundStyle(.secondary).lineLimit(3)
                            .accessibilityLabel("Speech preview: " + model.partialTranscript)
                    }
                    if !model.goal.isEmpty {
                        Text("Task: " + model.goal).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if !model.transcript.isEmpty {
                        Text(model.transcript).font(.body.weight(.medium)).lineLimit(4)
                    }
                    Text(model.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("voice-control-status")
                    if model.microphoneOn {
                        ProgressView(value: Double(model.audioLevel)).accessibilityLabel("Microphone level")
                    }
                    if model.conversation.expectedResponse == .confirmation {
                        HStack {
                            Button("Confirm this action", action: { model.onConfirm?() }).parakeetAction(
                                .primaryProminent)
                            Button("Cancel task", action: { model.onCancel?() }).parakeetAction(.secondary)
                        }
                    }
                    HStack {
                        if model.microphoneOn {
                            Button("Finish speaking", action: { model.onCommit?() }).parakeetAction(.secondary)
                            Button("Mic off", action: { model.onStopListening?() }).parakeetAction(.secondary)
                        } else {
                            Button("Start listening", action: { model.onListen?() }).parakeetAction(.primary)
                        }
                        Button("Stop", action: { model.onStop?() }).parakeetAction(.secondary)
                            .keyboardShortcut(.cancelAction)
                        if model.phase == .paused {
                            Button("Continue", action: { model.onResume?() }).parakeetAction(.secondary)
                        }
                    }
                    HStack {
                        TextField("Instruction or correction", text: $model.input)
                            .textFieldStyle(.roundedBorder).onSubmit(submit)
                        Button("Go", action: submit).parakeetAction(.secondary)
                            .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !model.steps.isEmpty {
                        DisclosureGroup("Task activity", isExpanded: $model.activityExpanded) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(model.steps.enumerated()), id: \.offset) { _, step in
                                    Text(step).font(.caption).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(.top, 8)
                        }
                    }
                    DisclosureGroup("Diagnostics", isExpanded: $model.diagnosticsExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.diagnosticsStatus).font(.caption).foregroundStyle(.secondary)
                            Text(model.diagnosticsLogPath)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Refresh", action: { model.onRefreshDiagnostics?() }).parakeetAction(.subtle)
                                Button("Open folder", action: { model.onOpenDiagnosticsFolder?() }).parakeetAction(.subtle)
                            }
                            HStack {
                                Button("Copy log path", action: { model.onCopyDiagnosticsPath?() }).parakeetAction(.subtle)
                                Button("Copy diagnostics", action: { model.onCopyDiagnostics?() }).parakeetAction(.subtle)
                                    .disabled(model.diagnosticsText.isEmpty)
                            }
                            Text("Copy diagnostics omits the instruction and labels so it is safer to paste.")
                                .font(.caption2).foregroundStyle(.secondary)
                            if !model.diagnosticsText.isEmpty {
                                ScrollView([.vertical, .horizontal]) {
                                    Text(model.diagnosticsText).font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled).padding(6)
                                }.frame(maxHeight: 220)
                            }
                        }.padding(.top, 8)
                    }
                    .onChange(of: model.diagnosticsExpanded) { _, expanded in
                        if expanded { model.onRefreshDiagnostics?() }
                    }
                    HStack {
                        Text("Hold \(model.holdTrigger.shortSymbol) · Escape stops").font(.caption).foregroundStyle(
                            .secondary)
                        Spacer()
                        Button("End", action: { model.onEnd?() }).parakeetAction(.subtle)
                        Button("Setup", action: { model.onSettings?() }).parakeetAction(.subtle)
                    }
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 470, height: model.needsSetup ? 510 : 470)
        .background(.regularMaterial)
    }
    private func submit() {
        let value = model.input
        model.input = ""
        model.onSubmit?(value)
    }
}

@MainActor
final class VoiceControlPanelController {
    private let panel: NSPanel
    private let model: VoiceControlViewModel
    init(model: VoiceControlViewModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 330),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Voice Control"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: VoiceControlPanelView(model: model))
    }
    func show() {
        panel.setContentSize(NSSize(width: 470, height: model.needsSetup ? 510 : 470))
        if !panel.isVisible, let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 490, y: frame.maxY - 32))
        }
        panel.orderFrontRegardless()
    }
    func owns(event: NSEvent) -> Bool { event.window === panel }
    func hide() { panel.orderOut(nil) }
}
