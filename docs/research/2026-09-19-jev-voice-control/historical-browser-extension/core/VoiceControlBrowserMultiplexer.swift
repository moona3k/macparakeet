import Foundation

/// Switches to a user-authorized browser tab when connected. Once used, loss of
/// that browser context requires explicit useNative() rather than rerouting effects.
public actor VoiceControlBrowserMultiplexer: VoiceControlAdapter {
    private let native: any VoiceControlAdapter
    public let browser: VoiceControlBrowserAdapter
    private var browserWasSelected = false
    private var snapshots: [UUID: Bool] = [:]
    public init(native: any VoiceControlAdapter, browser: VoiceControlBrowserAdapter) {
        self.native = native; self.browser = browser
    }
    /// Call when the user explicitly enables Voice Control. No pairing means AX only.
    public func startBrowserIfPaired() async throws {
        let config = VoiceControlBrowserWire.directory.appendingPathComponent("pairing.json")
        guard FileManager.default.fileExists(atPath: config.path) else { return }
        try await browser.start()
    }
    public func stop() async {
        await browser.stop(); snapshots.removeAll(); browserWasSelected = false
    }
    public func useNative() {
        snapshots.removeAll(); browserWasSelected = false
    }
    public func observe() async throws -> VoiceControlSnapshot {
        let connected = await browser.isConnected
        let selected = connected || browserWasSelected
        if selected { browserWasSelected = true }
        let snapshot = try await (selected ? browser : native).observe()
        snapshots = [snapshot.id: selected]
        return snapshot
    }
    public func execute(
        action: VoiceControlAction, snapshot: VoiceControlSnapshot,
        authority: ActionAuthority
    ) async throws -> VoiceControlReceipt {
        guard let selected = snapshots.removeValue(forKey: snapshot.id) else {
            throw VoiceControlBrowserAdapter.BridgeError.remoteFailure
        }
        return try await (selected ? browser : native).execute(action: action, snapshot: snapshot, authority: authority)
    }
}
