import Foundation

/// An approval identifies the configured endpoint and model, never a credential.
public struct AskProviderDisclosure: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let model: String
    public let endpoint: String
    public let requiresRemoteConsent: Bool

    public init(id: String, name: String, model: String, endpoint: String, requiresRemoteConsent: Bool) {
        self.id = id
        self.name = name
        self.model = model
        self.endpoint = endpoint
        self.requiresRemoteConsent = requiresRemoteConsent
    }
}

public struct AskEvidence: Codable, Sendable {
    public let status: AskEvidenceStatus
    public let source: AskSourceDescriptor?
    public let passage: AskPassage?

    public init(status: AskEvidenceStatus, source: AskSourceDescriptor?, passage: AskPassage?) {
        self.status = status
        self.source = source
        self.passage = passage
    }
}

/// Shared native and automation surface. Cancellation is task cancellation;
/// callers await its settlement before mutating a running conversation.
public protocol AskWorkspaceServing: Sendable {
    func conversations() async throws -> [AskConversation]
    func conversation(id: UUID) async throws -> AskConversation?
    func create(sourceIDs: [UUID]) async throws -> AskConversation
    func rename(id: UUID, title: String, expectedRevision: Int) async throws -> AskConversation
    func delete(id: UUID) async throws
    func selectSources(id: UUID, sourceIDs: [UUID], expectedRevision: Int) async throws -> AskConversation
    func saveDraft(id: UUID, draft: String, expectedRevision: Int) async throws -> AskConversation
    func sources(filter: AskSourceFilter) async throws -> [AskSourceDescriptor]
    func sourceSnapshots(ids: [UUID]) async throws -> [AskSourceSnapshot]
    func labels() async throws -> [MeetingLabel]
    func provider() async throws -> AskProviderDisclosure
    func evidence(_ reference: AskEvidenceReference) async throws -> AskEvidence
    func send(
        id: UUID,
        question: String,
        expectedRevision: Int,
        approvedProviderID: String?,
        onEvent: @escaping @Sendable (AskAgentEvent) async -> Void
    ) async throws -> AskConversation
}
