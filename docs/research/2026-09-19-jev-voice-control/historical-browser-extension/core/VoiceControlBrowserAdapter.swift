import Darwin
import Foundation

/// Browser-scoped adapter. A disconnected authorized tab never silently falls back to another app.
public actor VoiceControlBrowserAdapter: VoiceControlAdapter {
    private struct NotDispatched: Error {}
    public enum BridgeError: Error, LocalizedError {
        case notConnected, invalidResponse, remoteFailure, timedOut, alreadyRunning
        public var errorDescription: String? {
            switch self {
            case .notConnected: return "Connect the chosen browser tab using the Voice Control extension."
            case .invalidResponse: return "The browser returned an invalid response."
            case .remoteFailure: return "The browser context changed. Observe the chosen tab again."
            case .timedOut: return "The browser did not acknowledge the action. Check the page before continuing."
            case .alreadyRunning: return "Another Voice Control browser bridge is already running."
            }
        }
    }
    private var listener: VoiceControlBrowserListener?
    private var connection: VoiceControlBrowserConnection?
    private var connectionID: UUID?
    private var configuration: VoiceControlBrowserWire.Configuration?
    private var sessionID: String?
    private var contextID: String?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var executionRequests: Set<String> = []
    public var isConnected: Bool { sessionID != nil && contextID != nil && connection != nil }
    public init() {}

    public func start() throws {
        guard listener == nil else { return }
        configuration = try VoiceControlBrowserWire.configuration()
        listener = try VoiceControlBrowserListener { [weak self] peer in
            Task { await self?.accept(peer) }
        }
    }

    public func stop() {
        disconnect()
        listener?.close(); listener = nil
        configuration = nil
    }

    private func accept(_ peer: VoiceControlBrowserConnection) {
        // One explicitly connected profile owns the bridge. A second profile cannot replace it.
        guard connection == nil else { peer.close(); return }
        connection = peer
        let id = UUID(); connectionID = id
        peer.read { [weak self] data in Task { await self?.receive(data, from: id) } }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.expireUnauthenticated(id)
        }
    }

    private func expireUnauthenticated(_ id: UUID) {
        if id == connectionID && sessionID == nil { disconnect() }
    }

    private func disconnect() {
        connection?.close(); connection = nil; connectionID = nil
        sessionID = nil; contextID = nil
        let waiting = pending; pending.removeAll(); executionRequests.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: BridgeError.notConnected) }
    }

    private func receive(_ data: Data?, from id: UUID) {
        guard id == connectionID else { return }
        guard let data,
            let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = message["type"] as? String
        else { disconnect(); return }
        if type == "hostHello" {
            guard sessionID == nil, let configuration,
                message["token"] as? String == configuration.token,
                message["origin"] as? String == configuration.extensionOrigin
            else { disconnect(); return }
            sessionID = UUID().uuidString
            try? send(["type": "hostReady"])
            return
        }
        guard let sessionID else { disconnect(); return }
        if type == "authorize" {
            guard let context = message["contextID"] as? String, !context.isEmpty, context.count <= 512 else {
                disconnect(); return
            }
            // Reauthorization revokes every old observation and outstanding request.
            invalidateObservations()
            contextID = context
            try? send(["type": "authorized", "sessionID": sessionID, "contextID": context])
        } else if type == "invalidate" {
            contextID = nil
            invalidateObservations()
        } else if type == "disconnect" {
            disconnect()
        } else if type == "response", message["sessionID"] as? String == sessionID,
            let requestID = message["requestID"] as? String,
            let continuation = pending.removeValue(forKey: requestID)
        {
            executionRequests.remove(requestID)
            guard message["ok"] as? Bool == true,
                let payload = message["payload"], JSONSerialization.isValidJSONObject(payload),
                let encoded = try? JSONSerialization.data(withJSONObject: payload)
            else {
                continuation.resume(throwing: BridgeError.remoteFailure); return
            }
            continuation.resume(returning: encoded)
        }
    }

    private func invalidateObservations() {
        // Pending dispatches are invalidated remotely by document/context binding.
        // Keep their receipt waiters: navigation may be the effect they dispatched.
        for id in pending.keys.filter({ !executionRequests.contains($0) }) {
            pending.removeValue(forKey: id)?.resume(throwing: BridgeError.remoteFailure)
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let connection else { throw BridgeError.notConnected }
        try connection.write(JSONSerialization.data(withJSONObject: object))
    }

    private func request(type: String, payload: Data? = nil, authority: ActionAuthority? = nil) async throws -> Data {
        guard let sessionID, let contextID, connection != nil else { throw BridgeError.notConnected }
        let requestID = UUID().uuidString
        var message: [String: Any] = [
            "type": type, "requestID": requestID, "sessionID": sessionID, "contextID": contextID,
            "expiresAt": Date().addingTimeInterval(type == "execute" ? 0.75 : 4).timeIntervalSince1970 * 1000,
        ]
        if let payload { message["payload"] = try JSONSerialization.jsonObject(with: payload) }
        let data = try JSONSerialization.data(withJSONObject: message)
        let peer = connection!
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = continuation
                if type == "execute" { executionRequests.insert(requestID) }
                do {
                    if Task.isCancelled { throw CancellationError() }
                    // This is the dispatch boundary. Remote effects already dispatched cannot be unsent.
                    if let authority { try authority.perform { try peer.write(data) } } else { try peer.write(data) }
                } catch {
                    executionRequests.remove(requestID)
                    pending.removeValue(forKey: requestID)?.resume(
                        throwing: error is CancellationError ? NotDispatched() : error)
                    return
                }
                Task { [weak self] in
                    for _ in 0..<250 {
                        try? await Task.sleep(for: .milliseconds(20))
                        if let authority, !authority.isValid {
                            await self?.expire(requestID, cancelled: true); return
                        }
                        guard await self?.hasPending(requestID) == true else { return }
                    }
                    await self?.expire(requestID, cancelled: false)
                }
            }
        } onCancel: {
            Task { await self.expire(requestID, cancelled: true) }
        }
    }

    private func hasPending(_ id: String) -> Bool { pending[id] != nil }
    private func expire(_ id: String, cancelled: Bool) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        executionRequests.remove(id)
        try? send(["type": "revoke", "requestID": id, "sessionID": sessionID ?? ""])
        continuation.resume(throwing: cancelled ? CancellationError() : BridgeError.timedOut)
    }

    public func observe() async throws -> VoiceControlSnapshot {
        // Same-origin navigation keeps tab authorization but invalidates its old document.
        // Wait briefly for the replacement content script instead of falling back to AX.
        for _ in 0..<100 where sessionID != nil && contextID == nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        let data = try await request(type: "observe")
        let snapshot = try JSONDecoder().decode(VoiceControlSnapshot.self, from: data)
        guard snapshot.contextID == contextID, snapshot.targets.count <= 200,
            Set(snapshot.targets.map(\.id)).count == snapshot.targets.count,
            snapshot.summary.count <= 6_000
        else { throw BridgeError.invalidResponse }
        return snapshot
    }

    public func execute(
        action: VoiceControlAction, snapshot: VoiceControlSnapshot,
        authority: ActionAuthority
    ) async throws -> VoiceControlReceipt {
        guard snapshot.contextID == contextID,
            snapshot.targets.contains(where: { $0.id == action.targetID && $0.operations.contains(action.operation) })
        else {
            throw BridgeError.remoteFailure
        }
        struct Execution: Encodable { let action: VoiceControlAction; let snapshotID: UUID }
        let payload = try JSONEncoder().encode(Execution(action: action, snapshotID: snapshot.id))
        try authority.check()
        try Task.checkCancellation()
        do {
            let data = try await request(type: "execute", payload: payload, authority: authority)
            struct Result: Decodable { let status: String }
            let result = try JSONDecoder().decode(Result.self, from: data)
            guard let status = VoiceControlReceipt.Status(rawValue: result.status) else {
                throw BridgeError.invalidResponse
            }
            return VoiceControlReceipt(status: status)
        } catch is NotDispatched {
            throw CancellationError()
        } catch is CancellationError {
            // The remote side may already have dispatched. Never replay an interrupted request.
            return VoiceControlReceipt(status: .unknown, message: "Browser action interrupted; check the page.")
        } catch {
            return VoiceControlReceipt(
                status: .unknown, message: "Browser effect was not acknowledged; check the page.")
        }
    }
}

private final class VoiceControlBrowserConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { throw VoiceControlBrowserWire.WireError.disconnected }
        try VoiceControlBrowserWire.writeFrame(data, to: descriptor)
    }
    func read(_ callback: @escaping @Sendable (Data?) -> Void) {
        lock.lock(); let fd = Darwin.dup(descriptor); lock.unlock()
        DispatchQueue(label: "voice-control.browser.read").async {
            defer { Darwin.close(fd) }
            do { while true { callback(try VoiceControlBrowserWire.readFrame(from: fd)) } } catch { callback(nil) }
        }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor); descriptor = -1
    }
    deinit { close() }
}

private final class VoiceControlBrowserListener: @unchecked Sendable {
    private let descriptor: Int32
    private let lockDescriptor: Int32
    private let lock = NSLock()
    private var closed = false
    init(accept: @escaping @Sendable (VoiceControlBrowserConnection) -> Void) throws {
        let directory = VoiceControlBrowserWire.directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        else {
            throw VoiceControlBrowserWire.WireError.invalidConfiguration
        }
        let lockFD = Darwin.open(
            directory.appendingPathComponent("bridge.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw VoiceControlBrowserWire.WireError.socketFailure }
        var lockAttributes = stat()
        guard fstat(lockFD, &lockAttributes) == 0, lockAttributes.st_uid == getuid(),
            lockAttributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), lockAttributes.st_mode & 0o777 == 0o600,
            flock(lockFD, LOCK_EX | LOCK_NB) == 0
        else {
            Darwin.close(lockFD); throw VoiceControlBrowserAdapter.BridgeError.alreadyRunning
        }
        let fd: Int32
        do { fd = try VoiceControlBrowserWire.makeSocket() } catch { Darwin.close(lockFD); throw error }
        do {
            let path = VoiceControlBrowserWire.socketPath
            try VoiceControlBrowserWire.bindRecoveringStaleSocket(fd, path: path)
            guard chmod(path, 0o600) == 0, Darwin.listen(fd, 2) == 0 else {
                Darwin.unlink(path); throw VoiceControlBrowserWire.WireError.socketFailure
            }
        } catch { Darwin.close(fd); Darwin.close(lockFD); throw error }
        descriptor = fd
        lockDescriptor = lockFD
        DispatchQueue(label: "voice-control.browser.accept").async { [weak self] in
            while let self, !self.isClosed {
                let peer = Darwin.accept(fd, nil, nil)
                if peer < 0 { return }
                accept(VoiceControlBrowserConnection(peer))
            }
        }
    }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor)
        Darwin.unlink(VoiceControlBrowserWire.socketPath)
        Darwin.close(lockDescriptor)
    }
    deinit { close() }
}
