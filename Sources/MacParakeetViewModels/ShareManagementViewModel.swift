import Foundation
import MacParakeetCore
import Observation

/// A small UI testing seam; all production authority and persistence stay in Core.
public protocol ShareManaging: Sendable {
    func listPublications() async throws -> [SharePublication]
    func refreshPublications() async throws -> [SharePublication]
    func pendingOperations(shareId: UUID) async throws -> [ShareOutboxOperation]
    func confirmedLink(shareId: UUID) async throws -> ShareLink?
    func publish(bundle: ShareBundle, transcriptionId: UUID?, expiresAt: Date?, projectionManifest: Data?, contentDigest: String?) async throws -> SharePublishResult
    func updateContent(shareId: UUID, bundle: ShareBundle, projectionManifest: Data?, contentDigest: String?) async throws -> SharePublication
    func changeExpiry(shareId: UUID, newExpiresAt: Date) async throws -> SharePublication
    func stop(shareId: UUID) async throws -> SharePublication
    func resumePendingWork() async
    func forgetCompletedPublication(shareId: UUID) async throws
    func setUpRecovery() async throws -> ShareRecoverySetupResult
    func replaceRecovery(currentRecoveryToken: ShareRecoveryToken) async throws -> ShareRecoverySetupResult
    func removeRecovery(currentRecoveryToken: ShareRecoveryToken) async throws -> ShareOwnerMetadata
    func pendingRecoveryCode() async throws -> ShareRecoveryToken?
    func acknowledgeRecoveryCodeSaved() async throws
    func reconcileLostRecoveryConfiguration() async throws -> ShareOwnerMetadata?
    func recoverOwnership(recoveryToken: ShareRecoveryToken, replacementRecoveryVerifier: String?) async throws -> ShareOwnerMetadata
    func reconcileLostRecoveryImport() async throws -> Bool
    func discardCredentialAfterRecoveryLoss() async throws
}

extension ShareCoordinator: ShareManaging {}

@MainActor
@Observable
public final class ShareManagementViewModel {
    public typealias SourceLoader = @Sendable (UUID) async throws -> ShareDraftSource?
    public private(set) var publications: [SharePublication] = []
    public private(set) var pending: [UUID: [ShareOutboxOperation.Kind]] = [:]
    public private(set) var links: [UUID: ShareLink] = [:]
    public private(set) var titles: [UUID: String] = [:]
    public private(set) var staleIDs: Set<UUID> = []
    public private(set) var availableSourceIDs: Set<UUID> = []
    public private(set) var isBusy = false
    public private(set) var credentialSuperseded = false
    public private(set) var errorMessage: String?
    public private(set) var recoveryCode: String?
    public private(set) var recoveryMessage: String?
    public var draft: ShareDraftViewModel?
    private var service: (any ShareManaging)?
    private var sourceLoader: SourceLoader?
    private var draftRequest = UUID()

    public init() {}

    public func configure(service: any ShareManaging, sourceLoader: @escaping SourceLoader) {
        self.service = service; self.sourceLoader = sourceLoader
    }

    public var isConfigured: Bool { service != nil }

    public func presentDraft(source: ShareDraftSource, selectedSummaryID: UUID? = nil) {
        guard let service, !isBusy else { return }
        draftRequest = UUID()
        draft = ShareDraftViewModel(source: source, service: service, selectedSummaryID: selectedSummaryID)
    }

    public func prepareDraft(for share: SharePublication, updating: Bool) async {
        guard let service, let sourceLoader, let sourceID = share.transcriptionId, !isBusy else { return }
        if updating && !canUpdate(share) { return }
        let request = UUID(); draftRequest = request
        isBusy = true
        defer { isBusy = false }
        do {
            guard let source = try await sourceLoader(sourceID), request == draftRequest else {
                errorMessage = "The source is no longer in your Library. Its existing link remains manageable here."
                return
            }
            draft = ShareDraftViewModel(source: source, service: service, updating: updating ? share : nil)
        } catch { record(error) }
    }

    public func refresh() async {
        guard let service, !isBusy, draft?.isPublishing != true else { return }
        await perform {
            try await self.loadLocal()
            _ = try await service.reconcileLostRecoveryImport()
            _ = try await service.reconcileLostRecoveryConfiguration()
            await service.resumePendingWork()
            _ = try await service.refreshPublications()
        }
    }

    public func stop(_ share: SharePublication) async {
        guard let service else { return }
        await perform { _ = try await service.stop(shareId: share.id) }
    }

    public func changeExpiry(_ share: SharePublication, to date: Date) async {
        guard let service else { return }
        guard date > Date(), date <= share.maxExpiresAt, date.timeIntervalSince1970.rounded(.down) == date.timeIntervalSince1970 else {
            errorMessage = "Choose a future expiration within the original 90-day limit, using whole seconds."
            return
        }
        await perform { _ = try await service.changeExpiry(shareId: share.id, newExpiresAt: date) }
    }

    public func forget(_ share: SharePublication) async {
        guard let service, share.deletionState == .complete, pending[share.id, default: []].isEmpty else { return }
        await perform { try await service.forgetCompletedPublication(shareId: share.id) }
    }

    public func canManage(_ share: SharePublication) -> Bool {
        !isBusy && !credentialSuperseded && share.accessState == .active && share.expiresAt > Date()
            && pending[share.id, default: []].isEmpty
    }

    public func canUpdate(_ share: SharePublication) -> Bool {
        canManage(share) && share.isContentUpdateEligibleLocally && links[share.id] != nil && availableSourceIDs.contains(share.id)
    }

    public func status(for share: SharePublication) -> String {
        let work = pending[share.id, default: []]
        if credentialSuperseded { return "Management moved to another installation" }
        if work.contains(.delete) && !share.isTerminal { return "Stop pending — the link may still work" }
        if share.deletionState == .complete { return "Access stopped; encrypted copy deleted" }
        if share.isTerminal { return "\(share.accessState == .expired ? "Expired" : "Stopped permanently"); encrypted copy deletion pending" }
        if share.expiresAt <= Date() { return "Expired; cleanup confirmation pending" }
        if !share.isConfirmed { return "Publication pending — no confirmed link yet" }
        if work.contains(.contentUpdate) { return "Update pending — the previous revision remains shared" }
        if work.contains(.expiryChange) { return "Expiration change pending — previous expiration still applies" }
        if staleIDs.contains(share.id) { return "Local content changed — shared page has not changed" }
        return share.contentWritable && links[share.id] != nil ? "Active snapshot" : "Active — management only on this Mac"
    }

    public func setUpRecovery() async {
        guard let service else { return }
        await perform {
            let result = try await service.setUpRecovery()
            self.recoveryCode = result.recoveryToken.rawValue
            self.recoveryMessage = "Save this code somewhere safe. It is shown only after the service confirms it."
        }
    }

    public func replaceRecovery(proof: String) async {
        guard let service else { return }
        await perform {
            let token = try ShareRecoveryToken(rawValue: proof.trimmingCharacters(in: .whitespacesAndNewlines))
            self.recoveryCode = try await service.replaceRecovery(currentRecoveryToken: token).recoveryToken.rawValue
            self.recoveryMessage = "Your previous recovery code no longer works. Save this replacement."
        }
    }

    public func removeRecovery(proof: String) async {
        guard let service else { return }
        await perform {
            let token = try ShareRecoveryToken(rawValue: proof.trimmingCharacters(in: .whitespacesAndNewlines))
            _ = try await service.removeRecovery(currentRecoveryToken: token)
            self.recoveryCode = nil
            self.recoveryMessage = "Recovery is no longer configured. This Mac can still manage its links."
        }
    }

    public func importRecovery(code: String) async {
        guard let service else { return }
        await perform {
            let token = try ShareRecoveryToken(rawValue: code.trimmingCharacters(in: .whitespacesAndNewlines))
            _ = try await service.recoverOwnership(recoveryToken: token, replacementRecoveryVerifier: nil)
            self.credentialSuperseded = false
            self.recoveryMessage = "Management restored. Earlier links are management-only; new sharing works normally. Set up and save a replacement recovery code."
            _ = try await service.refreshPublications()
        }
    }

    public func acknowledgeRecoverySaved() async {
        guard let service else { return }
        await perform { try await service.acknowledgeRecoveryCodeSaved(); self.recoveryCode = nil }
    }

    public func startFreshOwner() async {
        guard let service else { return }
        await perform {
            try await service.discardCredentialAfterRecoveryLoss()
            self.credentialSuperseded = false
            self.recoveryMessage = "Ready for a new anonymous owner on your next publication."
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do { try await action() } catch { record(error) }
        do { try await loadLocal() } catch { record(error) }
    }

    private func loadLocal() async throws {
        guard let service else { return }
        publications = try await service.listPublications()
        var nextPending: [UUID: [ShareOutboxOperation.Kind]] = [:]
        var nextLinks: [UUID: ShareLink] = [:]
        var nextTitles: [UUID: String] = [:]
        var nextStale: Set<UUID> = [], nextSources: Set<UUID> = []
        for share in publications {
            let operations = try await service.pendingOperations(shareId: share.id)
            nextPending[share.id] = operations.map(\.kind)
            if !operations.contains(where: { $0.kind == .delete }), let link = try await service.confirmedLink(shareId: share.id) { nextLinks[share.id] = link }
            // Source enrichment is optional. A missing or unreadable Library
            // record must never block remote stop/expiry reconciliation.
            if let sourceID = share.transcriptionId, let sourceLoader, let source = try? await sourceLoader(sourceID) {
                nextTitles[share.id] = source.title; nextSources.insert(share.id)
                if let manifest = share.projectionManifest.flatMap({ try? JSONDecoder().decode(ShareProjectionManifest.self, from: $0) }), let digest = share.contentDigest {
                    let current = await Task.detached(priority: .utility) { try? source.bundle(manifest: manifest, publishedAt: share.updatedAt).contentDigest() }.value
                    if current != digest { nextStale.insert(share.id) }
                }
            }
        }
        pending = nextPending; links = nextLinks; titles = nextTitles; staleIDs = nextStale; availableSourceIDs = nextSources
        recoveryCode = try await service.pendingRecoveryCode()?.rawValue
    }

    private func record(_ error: Error) {
        if error as? ShareCoordinatorError == .deviceCredentialSuperseded { credentialSuperseded = true }
        errorMessage = Self.message(for: error)
    }

    public static func message(for error: Error) -> String {
        if let error = error as? ShareCoordinatorError {
            switch error {
            case .deviceCredentialSuperseded: return "Another installation recovered this owner. This Mac can no longer manage these links. Use your current recovery code to restore management."
            case .recoverySwitchBlocked, .sharesNotTerminal: return "Stop every existing link and wait for encrypted-copy deletion before switching owners. Your current credentials have been kept."
            case .operationInProgress: return "Another sharing operation is finishing. Please try again shortly."
            case .recoveryPending: return "Recovery confirmation is pending. Refresh to reconcile it before making another recovery change."
            case .contentKeyUnavailable, .contentUpdateNotEligible: return "This page is management-only on this Mac. You can change its expiration or stop it, but cannot recover its text or complete link."
            case .shareNotActive: return "This link is no longer active. Create a new link to share again."
            case .invalidExpiry: return "Choose a valid future expiration within the original 90-day limit."
            default: break
            }
        }
        if error is ShareCredentialTokenError { return "That recovery code is not valid. Paste the complete code, starting with mpr1."
        }
        if let client = error as? ShareClientError, case .api(let api) = client {
            switch api.code {
            case .versionConflict: return "The remote state changed. Refresh before trying again. An existing recovery code can only be replaced with proof of that code."
            case .quotaExceeded, .rateLimited: return "The sharing limit has been reached. Wait before trying again, or stop unused links."
            case .serviceUnavailable: return "New publication is temporarily unavailable. Existing links can still be stopped."
            case .unauthorized: return "The credential or recovery proof was not accepted. Your existing local management state has been preserved."
            default: break
            }
        }
        return "The service has not confirmed this change. Your draft and any queued work are kept on this Mac. Refresh Shared pages to reconcile before trying again."
    }
}
