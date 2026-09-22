import Foundation
import SwiftUI

/// Always-editable notes state for a saved meeting.
///
/// Edits are persisted after a short idle window. `flush()` lets navigation and
/// LLM actions wait for the latest draft so downstream consumers never observe
/// stale notes.
@MainActor
@Observable
public final class SavedMeetingNotesViewModel {
    public enum SaveState: Equatable, Sendable {
        case saved
        case saving
        case failed
        case deleted
    }

    public static let debounceInterval: Duration = .milliseconds(500)

    public private(set) var text = ""
    public private(set) var wordCount = 0
    public private(set) var saveState: SaveState = .saved
    public private(set) var meetingID: UUID?

    public var hasUnsavedChanges: Bool { revision != savedRevision }

    /// Includes derived work deferred until navigation, an AI action, or quit.
    public var hasPendingFlush: Bool {
        hasUnsavedChanges || (onFlush != nil && flushedRevision != savedRevision)
    }

    /// The app retains editors with pending work independently of a window.
    var onUnsavedChangesChange: (() -> Void)?

    public var textBinding: Binding<String> {
        Binding(
            get: { [weak self] in self?.text ?? "" },
            set: { [weak self] newValue in self?.applyEdit(newValue) }
        )
    }

    /// SwiftUI can render a new selection before its onChange handler runs.
    /// Never expose or mutate a previous meeting's notes in that interval.
    public func textBinding(for displayedMeetingID: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self, self.meetingID == displayedMeetingID else { return "" }
                return self.text
            },
            set: { [weak self] newValue in
                guard let self, self.meetingID == displayedMeetingID else { return }
                self.applyEdit(newValue)
            }
        )
    }

    private var persist: ((String) async -> Bool)?
    private var onFlush: (() async -> Void)?
    private var flushTask: Task<Void, Never>?
    private var flushedRevision = 0
    private var isMeetingDeleted: (() async throws -> Bool)?
    private var debounceTask: Task<Void, Never>?
    private var inFlightTask: Task<Bool, Never>?
    private var inFlightToken: UUID?
    private var inFlightRevision: Int?
    private var configurationToken = UUID()
    private var revision = 0
    private var savedRevision = 0
    private let waitForDebounce: (Duration) async throws -> Void

    public init() {
        waitForDebounce = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    }

    init(waitForDebounce: @escaping (Duration) async throws -> Void) {
        self.waitForDebounce = waitForDebounce
    }

    public func configure(
        meetingID: UUID,
        text: String?,
        isMeetingDeleted: (() async throws -> Bool)? = nil,
        onFlush: (() async -> Void)? = nil,
        persist: @escaping (String) async -> Bool
    ) {
        debounceTask?.cancel()
        debounceTask = nil
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightToken = nil
        inFlightRevision = nil
        flushTask?.cancel()
        flushTask = nil
        flushedRevision = 0
        configurationToken = UUID()
        self.onFlush = onFlush
        self.meetingID = meetingID
        self.persist = persist
        self.isMeetingDeleted = isMeetingDeleted
        self.text = text ?? ""
        wordCount = Self.wordCount(for: self.text)
        revision = 0
        savedRevision = 0
        saveState = .saved
    }

    /// Cancels the idle timer and waits until the latest draft is persisted.
    /// Returns `false` when persistence fails so callers can keep the user on
    /// the current screen instead of invoking an LLM with stale context.
    @discardableResult
    public func flush() async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil
        guard hasPendingFlush else { return true }
        let activeConfigurationToken = configurationToken
        if hasUnsavedChanges {
            do {
                if try await retireDraftIfMeetingWasDeleted() { return true }
            } catch {
                guard configurationToken == activeConfigurationToken else { return false }
                // A failed read is not proof of deletion. Keep the draft for retry.
                if hasUnsavedChanges {
                    saveState = .failed
                    return false
                }
            }
        }
        guard configurationToken == activeConfigurationToken else { return false }
        while hasPendingFlush {
            while hasUnsavedChanges {
                guard configurationToken == activeConfigurationToken else { return false }
                guard await persistCurrentRevision() else {
                    guard configurationToken == activeConfigurationToken else { return false }
                    // Deletion can race the initial existence check and the write.
                    do {
                        return try await retireDraftIfMeetingWasDeleted()
                    } catch {
                        guard configurationToken == activeConfigurationToken else { return false }
                        saveState = .failed
                        return false
                    }
                }
            }
            if let onFlush, flushedRevision != savedRevision {
                if let flushTask {
                    await flushTask.value
                } else {
                    let flushingRevision = savedRevision
                    let task = Task { @MainActor [weak self] in
                        await onFlush()
                        guard let self, self.configurationToken == activeConfigurationToken else { return }
                        self.flushedRevision = flushingRevision
                        self.flushTask = nil
                        self.onUnsavedChangesChange?()
                    }
                    flushTask = task
                    await task.value
                }
            }
            guard configurationToken == activeConfigurationToken else { return false }
            // An edit during the callback remains pending and is drained before
            // the action proceeds. Concurrent callers share the same callback.
        }
        return configurationToken == activeConfigurationToken
    }

    /// Only an authoritative, successful database read may retire the draft.
    /// Keep its text readable for copying while the old detail view is open.
    private func retireDraftIfMeetingWasDeleted() async throws -> Bool {
        guard let isMeetingDeleted else { return false }
        let activeConfigurationToken = configurationToken
        let wasDeleted = try await isMeetingDeleted()
        guard configurationToken == activeConfigurationToken, wasDeleted else { return false }
        debounceTask?.cancel()
        debounceTask = nil
        configurationToken = UUID()
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightToken = nil
        inFlightRevision = nil
        flushTask?.cancel()
        flushTask = nil
        savedRevision = revision
        flushedRevision = revision
        saveState = .deleted
        onUnsavedChangesChange?()
        return true
    }

    @discardableResult
    public func retry() async -> Bool {
        await flush()
    }

    public func cancelPendingSave() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func applyEdit(_ newValue: String) {
        guard saveState != .deleted else { return }
        text = newValue
        wordCount = Self.wordCount(for: newValue)
        revision += 1
        saveState = .saving
        onUnsavedChangesChange?()
        scheduleDebounce()
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.waitForDebounce(Self.debounceInterval)
            guard !Task.isCancelled else { return }
            _ = await self.persistCurrentRevision()
        }
    }

    private func persistCurrentRevision() async -> Bool {
        guard hasUnsavedChanges else { return true }
        let activeConfigurationToken = configurationToken
        if let inFlightTask {
            let awaitedRevision = inFlightRevision
            let saved = await inFlightTask.value
            guard configurationToken == activeConfigurationToken else { return false }
            guard hasUnsavedChanges else { return true }
            if awaitedRevision != revision {
                return await persistCurrentRevision()
            }
            return saved
        }
        guard let persist else {
            saveState = .failed
            return false
        }
        let savingRevision = revision
        let savingText = text
        let token = UUID()
        saveState = .saving
        let task = Task { @MainActor [weak self] in
            let saved = await persist(savingText)
            guard let self, self.configurationToken == activeConfigurationToken else { return saved }
            if saved {
                self.savedRevision = max(self.savedRevision, savingRevision)
                if self.revision == savingRevision {
                    self.saveState = .saved
                }
                self.onUnsavedChangesChange?()
            } else if self.revision == savingRevision {
                self.saveState = .failed
            }
            if self.inFlightToken == token {
                self.inFlightTask = nil
                self.inFlightToken = nil
                self.inFlightRevision = nil
            }
            return saved
        }
        inFlightToken = token
        inFlightRevision = savingRevision
        inFlightTask = task
        let saved = await task.value
        return configurationToken == activeConfigurationToken && saved
    }

    private static func wordCount(for text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }
}
