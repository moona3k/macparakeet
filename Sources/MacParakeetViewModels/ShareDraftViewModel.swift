import Foundation
import MacParakeetCore
import Observation

/// Local-only identifiers reconnect a reviewed selection to its source. This
/// manifest is never included in the encrypted wire bundle or service metadata.
public struct ShareProjectionManifest: Codable, Equatable, Sendable {
    public var summaryIDs: [UUID]
    public var includeNotes: Bool
    public var includeTranscript: Bool
    public var includeTimestamps: Bool
    public var includeSpeakerLabels: Bool
    public var includeMetadata: Bool

    public init(
        summaryIDs: [UUID] = [], includeNotes: Bool = false, includeTranscript: Bool = false,
        includeTimestamps: Bool = false, includeSpeakerLabels: Bool = false, includeMetadata: Bool = false
    ) {
        self.summaryIDs = summaryIDs
        self.includeNotes = includeNotes
        self.includeTranscript = includeTranscript
        self.includeTimestamps = includeTimestamps
        self.includeSpeakerLabels = includeSpeakerLabels
        self.includeMetadata = includeMetadata
    }
}

public struct ShareDraftSource: Sendable {
    public struct Summary: Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public let markdown: String
        public init(id: UUID, title: String, markdown: String) {
            self.id = id; self.title = title; self.markdown = markdown
        }
    }
    public let transcription: Transcription
    public let title: String
    public let summaries: [Summary]
    public init(transcription: Transcription, title: String, summaries: [Summary]) {
        self.transcription = transcription; self.title = title; self.summaries = summaries
    }

    public func bundle(manifest: ShareProjectionManifest, publishedAt: Date) throws -> ShareBundle {
        try ShareProjection.project(
            transcription: transcription,
            summaries: summaries.filter { manifest.summaryIDs.contains($0.id) }.map {
                ShareSummary(title: $0.title, markdown: $0.markdown)
            },
            selection: ShareSelection(
                includeSummary: !manifest.summaryIDs.isEmpty,
                includeNotes: manifest.includeNotes, includeTranscript: manifest.includeTranscript,
                transcriptOptions: TranscriptExportOptions(
                    includeTimestamps: manifest.includeTimestamps,
                    includeSpeakerLabels: manifest.includeSpeakerLabels,
                    includeMetadata: manifest.includeMetadata)),
            title: title, publishedAt: publishedAt
        )
    }
}

public enum SharePresentationCopy {
    public static let disclosure =
        "Only the text in this preview is encrypted and uploaded. Audio is never included. Anyone with the complete link can read, copy and forward it. The hosted viewer and recipient’s browser handle the decryption key."
    public static let stopConfirmation =
        "Stop this link permanently? It cannot be turned back on. This cannot erase copies people have already saved. If you are offline, the link may still work until the service confirms the stop."
    public static let recovery =
        "A saved recovery code restores management, not the text or complete links. Without it, losing this Mac’s sharing credentials means you cannot stop a link early. Every link still expires."
}

@MainActor
@Observable
public final class ShareDraftViewModel: Identifiable {
    public let id = UUID()
    public let source: ShareDraftSource
    public let updating: SharePublication?
    public var manifest: ShareProjectionManifest
    public var expiresAt: Date
    public private(set) var preview: ShareBundle?
    public private(set) var previewBytes = 0
    public private(set) var isPreparing = false
    public private(set) var isPublishing = false
    public private(set) var publication: SharePublication?
    public private(set) var link: ShareLink?
    public private(set) var errorMessage: String?
    private let service: any ShareManaging
    private let now: @Sendable () -> Date
    private let publishedAt: Date
    private var preparedManifest: ShareProjectionManifest?
    private var previewGeneration = 0

    public init(
        source: ShareDraftSource, service: any ShareManaging, updating: SharePublication? = nil,
        selectedSummaryID: UUID? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source; self.service = service; self.updating = updating; self.now = now
        publishedAt = now()
        expiresAt = updating?.expiresAt ?? Date(timeIntervalSince1970: floor(now().timeIntervalSince1970) + 2_592_000)
        if let data = updating?.projectionManifest,
            let saved = try? JSONDecoder().decode(ShareProjectionManifest.self, from: data)
        {
            manifest = saved
        } else if let selectedSummaryID {
            manifest = ShareProjectionManifest(summaryIDs: [selectedSummaryID])
        } else {
            let summaries = source.summaries.filter {
                !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let hasNotes = !(source.transcription.userNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            let meetingLike = source.transcription.sourceType == .meeting || !summaries.isEmpty || hasNotes
            manifest = ShareProjectionManifest(
                summaryIDs: summaries.map(\.id), includeNotes: hasNotes, includeTranscript: !meetingLike)
        }
    }

    public var canIncludeTimestamps: Bool {
        source.transcription.hasWordTimestamps && !source.transcription.isTranscriptEdited
    }
    public var canIncludeSpeakerLabels: Bool {
        source.transcription.hasSpeakerLabeledWords && !source.transcription.isTranscriptEdited
    }
    public var maximumExpiration: Date { updating?.maxExpiresAt ?? now().addingTimeInterval(7_776_000) }
    public var canPublish: Bool {
        preview != nil && preparedManifest == manifest && !isPreparing && !isPublishing && publication == nil
    }

    public func selectLifetime(seconds: TimeInterval) {
        guard !isPublishing else { return }
        expiresAt = Date(timeIntervalSince1970: floor(now().timeIntervalSince1970) + seconds)
    }

    public func preparePreview() async {
        guard !isPublishing else { return }
        if !canIncludeTimestamps { manifest.includeTimestamps = false }
        if !canIncludeSpeakerLabels { manifest.includeSpeakerLabels = false }
        previewGeneration += 1
        let generation = previewGeneration
        let source = source, selection = manifest, date = publishedAt
        isPreparing = true
        preview = nil
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let bundle = try source.bundle(manifest: selection, publishedAt: date)
                return (bundle, try bundle.encodedJSON().count)
            }.value
            guard generation == previewGeneration, selection == manifest else { return }
            preview = result.0; previewBytes = result.1; preparedManifest = selection; errorMessage = nil
        } catch {
            guard generation == previewGeneration else { return }
            errorMessage = "Select some nonempty text. A shared page can contain at most 2 MiB of text."
        }
        if generation == previewGeneration { isPreparing = false }
    }

    public func publish() async {
        guard canPublish, let bundle = preview else { return }
        let instant = now()
        guard expiresAt.timeIntervalSince1970.isFinite,
            expiresAt.timeIntervalSince1970.rounded(.down) == expiresAt.timeIntervalSince1970,
            expiresAt > instant, expiresAt <= maximumExpiration
        else {
            errorMessage = "Choose a future expiration within 90 days of the original publication, using whole seconds."
            return
        }
        isPublishing = true; errorMessage = nil
        defer { isPublishing = false }
        var existingIDs: Set<UUID> = []
        do {
            existingIDs = Set(try await service.listPublications().map(\.id))
            let manifestData = try JSONEncoder().encode(manifest)
            let digest = try await Task.detached(priority: .userInitiated) {
                try bundle.contentDigest()
            }.value
            if let updating {
                let result = try await service.updateContent(
                    shareId: updating.id, bundle: bundle, projectionManifest: manifestData, contentDigest: digest)
                publication = result
                if result.contentRevision > updating.contentRevision {
                    link = try await service.confirmedLink(shareId: result.id)
                }
            } else {
                let result = try await service.publish(
                    bundle: bundle, transcriptionId: source.transcription.id,
                    expiresAt: expiresAt, projectionManifest: manifestData, contentDigest: digest)
                publication = result.publication; link = result.link
            }
        } catch {
            errorMessage = ShareManagementViewModel.message(for: error)
            // A transport failure can occur after the durable outbox commit.
            // Do not turn a retry click into a second independent publication.
            if let updating {
                if let operations = try? await service.pendingOperations(shareId: updating.id),
                    operations.contains(where: { $0.kind == .contentUpdate })
                {
                    publication = updating
                }
            } else if let rows = try? await service.listPublications() {
                publication = rows.first {
                    !existingIDs.contains($0.id) && $0.transcriptionId == source.transcription.id
                        && $0.createdAt >= publishedAt.addingTimeInterval(-1)
                }
            }
        }
    }
}
