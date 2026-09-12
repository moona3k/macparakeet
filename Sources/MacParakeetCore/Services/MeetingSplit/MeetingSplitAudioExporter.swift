import AVFoundation
import Foundation

// MARK: - Inputs

/// One caller-approved child range to export, into a folder the caller
/// already owns exclusively (see `MeetingSplitAudioExporter`'s doc comment).
public struct MeetingSplitAudioChildRequest: Sendable, Equatable {
    public let childId: UUID
    public let range: MeetingSplitSourceRange
    public let destinationFolderURL: URL

    public init(childId: UUID, range: MeetingSplitSourceRange, destinationFolderURL: URL) {
        self.childId = childId
        self.range = range
        self.destinationFolderURL = destinationFolderURL
    }
}

// MARK: - Outputs

/// One exported audio file's alignment/size metadata. `startOffsetMs` is the
/// child-local offset (`a - s` in the contract's range-intersection math);
/// canonical playback is always on the child's own timeline, so its offset is
/// always zero.
public struct MeetingSplitExportedTrack: Sendable, Equatable {
    public let fileName: String
    public let startOffsetMs: Int
    public let durationMs: Int
    public let sizeBytes: Int64
    public let sampleRate: Double

    public init(fileName: String, startOffsetMs: Int, durationMs: Int, sizeBytes: Int64, sampleRate: Double) {
        self.fileName = fileName
        self.startOffsetMs = startOffsetMs
        self.durationMs = durationMs
        self.sizeBytes = sizeBytes
        self.sampleRate = sampleRate
    }
}

/// A missing optional source track and an in-range-but-non-overlapping track
/// both resolve to `nil` here: the caller must not assume a `nil` field means
/// "safe to zero-align," only "not exported for this child."
public struct MeetingSplitChildAudioExport: Sendable, Equatable {
    public let childId: UUID
    public let playback: MeetingSplitExportedTrack
    public let rawMicrophone: MeetingSplitExportedTrack?
    public let rawSystem: MeetingSplitExportedTrack?
    public let cleanedMicrophone: MeetingSplitExportedTrack?

    public init(
        childId: UUID,
        playback: MeetingSplitExportedTrack,
        rawMicrophone: MeetingSplitExportedTrack?,
        rawSystem: MeetingSplitExportedTrack?,
        cleanedMicrophone: MeetingSplitExportedTrack?
    ) {
        self.childId = childId
        self.playback = playback
        self.rawMicrophone = rawMicrophone
        self.rawSystem = rawSystem
        self.cleanedMicrophone = cleanedMicrophone
    }
}

/// A read-only snapshot of a saved recording's source media, returned by
/// `MeetingSplitAudioExporter.inspectSource(sourceFolderURL:)`. `durationMs`
/// is the authoritative whole-timeline duration callers should validate cut
/// points against; the `has*` flags describe alignment capability, i.e.
/// whether that optional track can be exported at all for this source.
public struct MeetingSplitSourceMediaInspection: Sendable, Equatable, Codable {
    /// One source file's cheap identity (size + modification time), used to
    /// detect a same-duration/same-size replacement without decoding or
    /// hashing the file's audio content. See `MeetingSplitSourceIdentity`.
    public struct FileIdentity: Sendable, Equatable, Codable {
        public let sizeBytes: Int64
        public let modifiedAt: Date?

        public init(sizeBytes: Int64, modifiedAt: Date?) {
            self.sizeBytes = sizeBytes
            self.modifiedAt = modifiedAt
        }
    }

    public let durationMs: Int
    public let sizeBytes: Int64
    public let hasRawMicrophone: Bool
    public let hasRawSystem: Bool
    public let hasCleanedMicrophone: Bool
    public let canonicalIdentity: FileIdentity
    public let rawMicrophoneIdentity: FileIdentity?
    public let rawSystemIdentity: FileIdentity?
    public let cleanedMicrophoneIdentity: FileIdentity?

    public init(
        durationMs: Int,
        sizeBytes: Int64,
        hasRawMicrophone: Bool,
        hasRawSystem: Bool,
        hasCleanedMicrophone: Bool,
        canonicalIdentity: FileIdentity,
        rawMicrophoneIdentity: FileIdentity?,
        rawSystemIdentity: FileIdentity?,
        cleanedMicrophoneIdentity: FileIdentity?
    ) {
        self.durationMs = durationMs
        self.sizeBytes = sizeBytes
        self.hasRawMicrophone = hasRawMicrophone
        self.hasRawSystem = hasRawSystem
        self.hasCleanedMicrophone = hasCleanedMicrophone
        self.canonicalIdentity = canonicalIdentity
        self.rawMicrophoneIdentity = rawMicrophoneIdentity
        self.rawSystemIdentity = rawSystemIdentity
        self.cleanedMicrophoneIdentity = cleanedMicrophoneIdentity
    }
}

public enum MeetingSplitAudioExportError: Error, Sendable, Equatable {
    case emptyChildRequests
    case emptyRange(childId: UUID)
    case sourceUnreadable(String)
    case sourceChanged(String)
    case malformedSource(String)
    case destinationAlreadyExists(String)
    /// A requested destination folder is the source folder itself, or nested
    /// inside/around it. The caller owns a fresh, exclusive destination
    /// folder per child that is never the session folder being read from;
    /// this rejects an identity mix-up before any directory is created.
    case destinationOverlapsSource(destination: String, source: String)
    case insufficientStorage(estimatedBytes: Int64, availableBytes: Int64)
    case writeFailed(String)
    /// Fewer frames were produced than requested, either because the writer
    /// stopped early (source ran out before the requested end) or the
    /// re-decoded output does not match what was asked for. The source is
    /// always left untouched; the partial destination file is removed.
    case truncatedOutput(fileName: String, expectedFrames: Int64, actualFrames: Int64)
}

/// Exports each caller-approved `MeetingSplitSourceRange` into independently
/// owned, correctly aligned media: canonical playback plus whichever raw
/// mic/system/cleaned-mic tracks are both present and actually overlap the
/// range.
///
/// This type does media preparation only. Callers already own an exclusively
/// held destination folder per child (final-path staging under a media
/// mutation lease); this exporter never invents its own staging, renaming or
/// publication step, never overwrites an existing destination file, and never
/// touches the source folder's contents. It returns plain metadata; the
/// caller decides how that metadata becomes a published row.
///
/// Export is bounded and sequential: one child, one track at a time, off the
/// main actor, so peak memory stays proportional to one buffer rather than a
/// whole recording. Every write loop is cooperatively cancellable and a
/// cancelled or failed slice leaves no partial destination file behind.
/// `FileManager` is documented as safe for concurrent use when no delegate is
/// installed; this box only exists to satisfy the `Sendable` closure-capture
/// check for the injected default-capacity lookup (mirrors the same pattern
/// in `MeetingPlaybackArtifactBuilder`).
private struct SendableFileManagerBox: @unchecked Sendable {
    let value: FileManager
    init(_ value: FileManager) { self.value = value }
}

/// Folder ownership contract: the caller passes one `sourceFolderURL` (an
/// existing, finalized session folder this exporter only ever reads) and one
/// `destinationFolderURL` per child (a folder path the caller already owns
/// exclusively and that does not yet contain the files this exporter writes).
/// `export(...)` rejects any child whose destination is the source folder
/// itself or nested inside/around it before creating anything, so a caller
/// bug can never turn a "read source, write child" call into a same-folder
/// read/write collision.
public actor MeetingSplitAudioExporter {
    /// Test-only synchronization seam. Production callers never set this;
    /// tests use it to pause the writer loop deterministically instead of
    /// racing a timer against cancellation.
    struct TestHooks: Sendable {
        var afterEachChunk: (@Sendable (Int) -> Void)?
        /// Fires once per chunk while the *source* probe (`decodedExtent`)
        /// decodes; lets a test observe that a probe is mid-flight before
        /// cancelling, the same way `afterEachChunk` does for the write loop.
        var afterEachProbeChunk: (@Sendable (Int) -> Void)?

        init(
            afterEachChunk: (@Sendable (Int) -> Void)? = nil,
            afterEachProbeChunk: (@Sendable (Int) -> Void)? = nil
        ) {
            self.afterEachChunk = afterEachChunk
            self.afterEachProbeChunk = afterEachProbeChunk
        }
    }

    private static let chunkFrameCapacity: AVAudioFrameCount = 32_768
    /// Multiplies the size-proportional estimate to cover AAC re-encode
    /// overhead and header/container slack; this is a bounded heuristic, not
    /// a guarantee of the final encoded size.
    private static let storageSafetyFactor: Double = 1.25
    private static let storageFixedOverheadBytes: Int64 = 8 * 1024 * 1024

    private let fileManager: FileManager
    private let availableCapacityBytes: @Sendable (URL) throws -> Int64
    private let testHooks: TestHooks

    public init(
        fileManager: FileManager = .default,
        availableCapacityBytes: (@Sendable (URL) throws -> Int64)? = nil
    ) {
        self.init(
            fileManager: fileManager,
            availableCapacityBytes: availableCapacityBytes,
            testHooks: TestHooks()
        )
    }

    init(
        fileManager: FileManager = .default,
        availableCapacityBytes: (@Sendable (URL) throws -> Int64)? = nil,
        testHooks: TestHooks
    ) {
        self.fileManager = fileManager
        let capacityFileManager = SendableFileManagerBox(fileManager)
        self.availableCapacityBytes =
            availableCapacityBytes ?? { url in
                try Self.defaultAvailableCapacity(at: url, fileManager: capacityFileManager.value)
            }
        self.testHooks = testHooks
    }

    // MARK: - Public entry point

    /// Export every requested child from the finalized source recording at
    /// `sourceFolderURL`. Resolves current/legacy filenames once, snapshots
    /// source identity and decoded extents once, preflights storage for the
    /// whole batch, then exports children one at a time. Any failure for one
    /// child throws immediately; already-written files for that child are
    /// removed, but earlier successfully returned children are the caller's
    /// concern (this exporter does not publish anything).
    public func export(
        sourceFolderURL: URL,
        sourceAlignment: MeetingSourceAlignment,
        children: [MeetingSplitAudioChildRequest]
    ) async throws -> [MeetingSplitChildAudioExport] {
        try Task.checkCancellation()
        guard !children.isEmpty else {
            throw MeetingSplitAudioExportError.emptyChildRequests
        }
        let standardizedSourceFolderURL = sourceFolderURL.standardizedFileURL
        for child in children {
            try Self.validateDestinationSeparation(
                destinationFolderURL: child.destinationFolderURL, sourceFolderURL: standardizedSourceFolderURL)
            // Reject a structurally invalid range before any source file is
            // opened or seeked: a negative start or a reversed/empty range is
            // a caller bug, not a partial-track or malformed-source case.
            try Self.validateStructurallySoundRange(child.range, childId: child.childId)
        }

        let resolved = try resolveSourceFiles(in: sourceFolderURL)
        let probeHook = testHooks.afterEachProbeChunk

        // Canonical playback must decode; a failure here really does make the
        // source ineligible for splitting.
        var identities: [URL: SourceIdentity] = [:]
        var extents: [URL: DecodedExtent] = [:]
        identities[resolved.playbackURL] = try identity(of: resolved.playbackURL)
        extents[resolved.playbackURL] = try await Self.runCancellably {
            try Self.decodedExtent(of: resolved.playbackURL, afterEachChunk: probeHook)
        }
        var usableSourceURLs = [resolved.playbackURL]

        // A damaged or unalignable optional raw/cleaned track must not make
        // otherwise-usable canonical playback ineligible: drop it (never
        // exported for any child) instead of failing the whole batch.
        for url in [resolved.rawMicrophoneURL, resolved.rawSystemURL, resolved.cleanedMicrophoneURL].compactMap({ $0 }) {
            try Task.checkCancellation()
            guard let probed = try await probeOptionalSourceTrack(url: url, afterEachChunk: probeHook) else { continue }
            identities[url] = probed.identity
            extents[url] = probed.extent
            usableSourceURLs.append(url)
        }

        try preflightStorage(
            sourceURLs: usableSourceURLs,
            identities: identities,
            playbackURL: resolved.playbackURL,
            extents: extents,
            children: children
        )

        var results: [MeetingSplitChildAudioExport] = []
        results.reserveCapacity(children.count)
        for child in children {
            try Task.checkCancellation()
            for url in usableSourceURLs {
                guard try identity(of: url) == identities[url] else {
                    throw MeetingSplitAudioExportError.sourceChanged(url.lastPathComponent)
                }
            }
            let exported = try await exportChild(
                child: child,
                resolved: resolved,
                extents: extents,
                sourceAlignment: sourceAlignment
            )
            results.append(exported)
        }

        for url in usableSourceURLs {
            guard try identity(of: url) == identities[url] else {
                throw MeetingSplitAudioExportError.sourceChanged(url.lastPathComponent)
            }
        }
        return results
    }

    /// Probes one optional (non-playback) source track. Returns `nil` when
    /// the track cannot be read or decoded — the caller treats that exactly
    /// like a missing track, not a batch failure — while still propagating
    /// cancellation rather than swallowing it.
    private func probeOptionalSourceTrack(
        url: URL,
        afterEachChunk: (@Sendable (Int) -> Void)?
    ) async throws -> (identity: SourceIdentity, extent: DecodedExtent)? {
        do {
            let sourceIdentity = try identity(of: url)
            let extent = try await Self.runCancellably {
                try Self.decodedExtent(of: url, afterEachChunk: afterEachChunk)
            }
            return (sourceIdentity, extent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Rejects a negative start, a reversed/empty range, before any source
    /// file is opened or seeked.
    private static func validateStructurallySoundRange(_ range: MeetingSplitSourceRange, childId: UUID) throws {
        guard range.startMs >= 0, range.endMs > range.startMs else {
            throw MeetingSplitAudioExportError.emptyRange(childId: childId)
        }
    }

    // MARK: - Read-only source inspection

    /// Read-only probe of a saved recording's source media: the authoritative
    /// whole-timeline duration (from canonical playback, the same file
    /// `export`'s ranges are measured against), on-disk size summed across
    /// every present source file, and which optional aligned tracks exist.
    /// No writes, no directory or lock creation. Callers that only need to
    /// preview or validate a source (for example the upcoming Core split
    /// service) should use this instead of re-probing source files themselves.
    public func inspectSource(sourceFolderURL: URL) async throws -> MeetingSplitSourceMediaInspection {
        try Task.checkCancellation()
        let resolved = try resolveSourceFiles(in: sourceFolderURL)
        let playbackExtent = try await Self.runCancellably {
            try Self.decodedExtent(of: resolved.playbackURL)
        }
        let canonicalIdentity = try identity(of: resolved.playbackURL)
        let rawMicrophoneIdentity = try resolved.rawMicrophoneURL.map { try identity(of: $0) }
        let rawSystemIdentity = try resolved.rawSystemURL.map { try identity(of: $0) }
        let cleanedMicrophoneIdentity = try resolved.cleanedMicrophoneURL.map { try identity(of: $0) }
        let totalSizeBytes =
            canonicalIdentity.size
            + (rawMicrophoneIdentity?.size ?? 0)
            + (rawSystemIdentity?.size ?? 0)
            + (cleanedMicrophoneIdentity?.size ?? 0)
        let durationMs = Int((Double(playbackExtent.frameCount) / playbackExtent.sampleRate * 1_000).rounded())
        return MeetingSplitSourceMediaInspection(
            durationMs: durationMs,
            sizeBytes: totalSizeBytes,
            hasRawMicrophone: resolved.rawMicrophoneURL != nil,
            hasRawSystem: resolved.rawSystemURL != nil,
            hasCleanedMicrophone: resolved.cleanedMicrophoneURL != nil,
            canonicalIdentity: .init(sizeBytes: canonicalIdentity.size, modifiedAt: canonicalIdentity.modifiedAt),
            rawMicrophoneIdentity: rawMicrophoneIdentity.map { .init(sizeBytes: $0.size, modifiedAt: $0.modifiedAt) },
            rawSystemIdentity: rawSystemIdentity.map { .init(sizeBytes: $0.size, modifiedAt: $0.modifiedAt) },
            cleanedMicrophoneIdentity: cleanedMicrophoneIdentity.map { .init(sizeBytes: $0.size, modifiedAt: $0.modifiedAt) }
        )
    }

    // MARK: - Source file resolution (shared by export and inspection)

    private struct ResolvedSourceFiles {
        let playbackURL: URL
        let rawMicrophoneURL: URL?
        let rawSystemURL: URL?
        let cleanedMicrophoneURL: URL?

        var all: [URL] {
            [playbackURL] + [rawMicrophoneURL, rawSystemURL, cleanedMicrophoneURL].compactMap { $0 }
        }
    }

    private func resolveSourceFiles(in sourceFolderURL: URL) throws -> ResolvedSourceFiles {
        let playbackResolution = MeetingArtifactAudioFileNames.resolvePlaybackURL(
            in: sourceFolderURL, fileManager: fileManager)
        guard playbackResolution.exists else {
            throw MeetingSplitAudioExportError.sourceUnreadable(MeetingArtifactAudioFileNames.playback)
        }
        let rawMicResolution = MeetingArtifactAudioFileNames.resolveRawMicrophoneURL(
            in: sourceFolderURL, fileManager: fileManager)
        let rawSystemResolution = MeetingArtifactAudioFileNames.resolveRawSystemURL(
            in: sourceFolderURL, fileManager: fileManager)
        let cleanedMicURL = sourceFolderURL.appendingPathComponent(MeetingArtifactAudioFileNames.cleanedMicrophone)
        let cleanedMicExists = fileManager.fileExists(atPath: cleanedMicURL.path)
        return ResolvedSourceFiles(
            playbackURL: playbackResolution.url,
            rawMicrophoneURL: rawMicResolution.exists ? rawMicResolution.url : nil,
            rawSystemURL: rawSystemResolution.exists ? rawSystemResolution.url : nil,
            cleanedMicrophoneURL: cleanedMicExists ? cleanedMicURL : nil
        )
    }

    /// Rejects a destination that is the source folder itself, or nested
    /// inside/around it, before any directory is created. See the ownership
    /// contract documented on `MeetingSplitAudioExporter` itself.
    private static func validateDestinationSeparation(destinationFolderURL: URL, sourceFolderURL: URL) throws {
        let destination = destinationFolderURL.standardizedFileURL.path
        let source = sourceFolderURL.standardizedFileURL.path
        guard destination != source,
            !destination.hasPrefix(source + "/"),
            !source.hasPrefix(destination + "/")
        else {
            throw MeetingSplitAudioExportError.destinationOverlapsSource(destination: destination, source: source)
        }
    }

    // MARK: - Per-child export

    private func exportChild(
        child: MeetingSplitAudioChildRequest,
        resolved: ResolvedSourceFiles,
        extents: [URL: DecodedExtent],
        sourceAlignment: MeetingSourceAlignment
    ) async throws -> MeetingSplitChildAudioExport {
        guard child.range.endMs > child.range.startMs else {
            throw MeetingSplitAudioExportError.emptyRange(childId: child.childId)
        }
        try fileManager.createDirectory(
            at: child.destinationFolderURL, withIntermediateDirectories: true)

        let playbackIntersection = try Self.playbackIntersection(
            range: child.range,
            extent: extents[resolved.playbackURL]!,
            fileName: resolved.playbackURL.lastPathComponent
        )
        let playback = try await sliceTrack(
            sourceURL: resolved.playbackURL,
            intersection: playbackIntersection,
            destinationURL: child.destinationFolderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback)
        )

        let rawMicrophone = try await sliceOptionalTrack(
            sourceURL: resolved.rawMicrophoneURL,
            extent: resolved.rawMicrophoneURL.flatMap { extents[$0] },
            trackStartOffsetMs: sourceAlignment.microphone?.startOffsetMs,
            range: child.range,
            destinationURL: child.destinationFolderURL.appendingPathComponent(
                MeetingArtifactAudioFileNames.rawMicrophone)
        )
        let rawSystem = try await sliceOptionalTrack(
            sourceURL: resolved.rawSystemURL,
            extent: resolved.rawSystemURL.flatMap { extents[$0] },
            trackStartOffsetMs: sourceAlignment.system?.startOffsetMs,
            range: child.range,
            destinationURL: child.destinationFolderURL.appendingPathComponent(
                MeetingArtifactAudioFileNames.rawSystem)
        )
        // The cleaned mic is rendered 1:1 with the raw mic (MeetingCleanedMicRenderer),
        // so it shares the raw mic's recorded start offset, but never its assumed
        // length: this exporter probes the cleaned file's own decoded extent.
        let cleanedMicrophone = try await sliceOptionalTrack(
            sourceURL: resolved.cleanedMicrophoneURL,
            extent: resolved.cleanedMicrophoneURL.flatMap { extents[$0] },
            trackStartOffsetMs: sourceAlignment.microphone?.startOffsetMs,
            range: child.range,
            destinationURL: child.destinationFolderURL.appendingPathComponent(
                MeetingArtifactAudioFileNames.cleanedMicrophone)
        )

        return MeetingSplitChildAudioExport(
            childId: child.childId,
            playback: playback,
            rawMicrophone: rawMicrophone,
            rawSystem: rawSystem,
            cleanedMicrophone: cleanedMicrophone
        )
    }

    private func sliceOptionalTrack(
        sourceURL: URL?,
        extent: DecodedExtent?,
        trackStartOffsetMs: Int?,
        range: MeetingSplitSourceRange,
        destinationURL: URL
    ) async throws -> MeetingSplitExportedTrack? {
        guard let sourceURL, let extent, let trackStartOffsetMs, trackStartOffsetMs >= 0 else {
            // Missing source, missing decode extent or unknown/invalid alignment
            // all mean the same thing here: we cannot promise a safe aligned
            // slice, so the track is omitted rather than zero-aligned.
            return nil
        }
        guard
            let intersection = Self.intersect(
                range: range,
                trackStartOffsetMs: trackStartOffsetMs,
                extent: extent
            )
        else {
            return nil
        }
        return try await sliceTrack(sourceURL: sourceURL, intersection: intersection, destinationURL: destinationURL)
    }

    private func sliceTrack(
        sourceURL: URL,
        intersection: TrackIntersection,
        destinationURL: URL
    ) async throws -> MeetingSplitExportedTrack {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw MeetingSplitAudioExportError.destinationAlreadyExists(destinationURL.lastPathComponent)
        }
        let expectedFrames = intersection.sourceLocalEndFrame - intersection.sourceLocalStartFrame

        let hooks = testHooks
        do {
            try await Self.runCancellably {
                try Self.reencodeSlice(
                    sourceURL: sourceURL,
                    startFrame: intersection.sourceLocalStartFrame,
                    endFrame: intersection.sourceLocalEndFrame,
                    destinationURL: destinationURL,
                    afterEachChunk: hooks.afterEachChunk
                )
            }
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        let verified: DecodedExtent
        do {
            verified = try await Self.runCancellably {
                try Self.decodedExtent(of: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
        // The writer already proved it wrote `expectedFrames`; re-decoding the
        // written file independently catches container/encoder quirks (for
        // example a trimmed edit list) that the writer side cannot see on its
        // own. Either mismatch means the output cannot be trusted, so it is
        // rejected rather than published with a silently wrong duration.
        guard verified.frameCount == expectedFrames else {
            try? fileManager.removeItem(at: destinationURL)
            throw MeetingSplitAudioExportError.truncatedOutput(
                fileName: destinationURL.lastPathComponent,
                expectedFrames: Int64(expectedFrames),
                actualFrames: Int64(verified.frameCount)
            )
        }
        guard let sizeBytes = try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber
        else {
            try? fileManager.removeItem(at: destinationURL)
            throw MeetingSplitAudioExportError.writeFailed(destinationURL.lastPathComponent)
        }
        let durationMs = Int((Double(verified.frameCount) / verified.sampleRate * 1_000).rounded())
        return MeetingSplitExportedTrack(
            fileName: destinationURL.lastPathComponent,
            startOffsetMs: intersection.childStartOffsetMs,
            durationMs: durationMs,
            sizeBytes: sizeBytes.int64Value,
            sampleRate: verified.sampleRate
        )
    }

    /// Runs `operation` on a detached, cooperatively-cancellable task and
    /// forwards this call's own cancellation into it, so a caller cancelling
    /// export never leaves a probe/verify decode running unattended after
    /// `export(...)` has already thrown `CancellationError`.
    private static func runCancellably<T: Sendable>(
        priority: TaskPriority = .utility,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Range intersection (shared endpoint conversion; see contract math)

    private struct TrackIntersection {
        let sourceLocalStartFrame: AVAudioFramePosition
        let sourceLocalEndFrame: AVAudioFramePosition
        let childStartOffsetMs: Int
    }

    /// `[s, e)` intersected with a track that starts at `o` and decodes to
    /// `extent`. Boundaries are converted to frames independently from the
    /// same millisecond value (never `start + separately-rounded duration`),
    /// so neighboring children that share a cut also share an exact frame
    /// index at that cut.
    private static func intersect(
        range: MeetingSplitSourceRange,
        trackStartOffsetMs: Int,
        extent: DecodedExtent
    ) -> TrackIntersection? {
        let trackDurationMs = Int((Double(extent.frameCount) / extent.sampleRate * 1_000).rounded())
        let a = max(range.startMs, trackStartOffsetMs)
        let b = min(range.endMs, trackStartOffsetMs + trackDurationMs)
        guard b > a else { return nil }
        let startFrame = msToFrame(a - trackStartOffsetMs, sampleRate: extent.sampleRate)
        let endFrame = min(msToFrame(b - trackStartOffsetMs, sampleRate: extent.sampleRate), extent.frameCount)
        let clampedStartFrame = min(startFrame, endFrame)
        guard endFrame > clampedStartFrame else { return nil }
        return TrackIntersection(
            sourceLocalStartFrame: clampedStartFrame,
            sourceLocalEndFrame: endFrame,
            childStartOffsetMs: a - range.startMs
        )
    }

    /// Canonical playback has no start offset: it is already on the shared
    /// timeline ranges are measured against. A playback file that decodes to
    /// less than the requested range is a malformed/mismatched source, not a
    /// partial-track skip.
    private static func playbackIntersection(
        range: MeetingSplitSourceRange,
        extent: DecodedExtent,
        fileName: String
    ) throws -> TrackIntersection {
        let durationMs = Int((Double(extent.frameCount) / extent.sampleRate * 1_000).rounded())
        guard durationMs >= range.endMs else {
            throw MeetingSplitAudioExportError.malformedSource(
                "\(fileName) decodes to \(durationMs)ms, short of the requested \(range.endMs)ms")
        }
        let startFrame = msToFrame(range.startMs, sampleRate: extent.sampleRate)
        // `durationMs` is rounded from the extent's true fractional duration,
        // so it can round DOWN below `extent.frameCount`'s exact millisecond
        // value. The final range's end always equals `durationMs` (ranges
        // cover exactly `[0, durationMs)`), so use the actual last decoded
        // frame there instead of re-deriving it from the rounded ms value,
        // which would silently drop the fractional tail frame.
        let endFrame = range.endMs >= durationMs
            ? extent.frameCount
            : min(msToFrame(range.endMs, sampleRate: extent.sampleRate), extent.frameCount)
        guard endFrame > startFrame else {
            throw MeetingSplitAudioExportError.malformedSource("\(fileName) produced an empty slice")
        }
        return TrackIntersection(
            sourceLocalStartFrame: startFrame, sourceLocalEndFrame: endFrame, childStartOffsetMs: 0)
    }

    private static func msToFrame(_ ms: Int, sampleRate: Double) -> AVAudioFramePosition {
        AVAudioFramePosition((Double(ms) * sampleRate / 1_000).rounded())
    }

    // MARK: - Decode/re-encode core (nonisolated; runs off the actor)

    struct DecodedExtent: Equatable {
        let frameCount: AVAudioFramePosition
        let sampleRate: Double
    }

    /// Fully decodes `url` to count real output frames and confirm the file
    /// actually decodes, rather than trusting container-reported duration.
    /// Reads in the same bounded chunk size as the write path, checking
    /// cancellation every chunk, so a probe over a long source stops promptly
    /// instead of running to completion after its caller has been cancelled.
    private nonisolated static func decodedExtent(
        of url: URL,
        afterEachChunk: (@Sendable (Int) -> Void)? = nil
    ) throws -> DecodedExtent {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw MeetingSplitAudioExportError.malformedSource(url.lastPathComponent)
        }
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingSplitAudioExportError.malformedSource(url.lastPathComponent)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCapacity) else {
            throw MeetingSplitAudioExportError.malformedSource(url.lastPathComponent)
        }
        var frames: AVAudioFramePosition = 0
        var chunkIndex = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: chunkFrameCapacity)
            guard buffer.frameLength > 0 else { break }
            frames += AVAudioFramePosition(buffer.frameLength)
            chunkIndex += 1
            afterEachChunk?(chunkIndex)
        }
        guard frames > 0 else {
            throw MeetingSplitAudioExportError.malformedSource(url.lastPathComponent)
        }
        return DecodedExtent(frameCount: frames, sampleRate: format.sampleRate)
    }

    /// Decode `[startFrame, endFrame)` of `sourceURL` and re-encode it as a
    /// fresh AAC `.m4a` at `destinationURL`. A robust decode/re-encode path,
    /// not a passthrough/composition optimization: every sample is read
    /// through `AVAudioFile` and re-written, so the result is exactly the
    /// requested frame range regardless of container edit-list quirks.
    private nonisolated static func reencodeSlice(
        sourceURL: URL,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition,
        destinationURL: URL,
        afterEachChunk: (@Sendable (Int) -> Void)?
    ) throws {
        guard endFrame > startFrame else {
            throw MeetingSplitAudioExportError.writeFailed("requested slice is empty")
        }
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw MeetingSplitAudioExportError.malformedSource(sourceURL.lastPathComponent)
        }
        let format = sourceFile.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
            sourceFile.length > 0
        else {
            throw MeetingSplitAudioExportError.malformedSource(sourceURL.lastPathComponent)
        }
        let clampedStart = max(0, min(startFrame, sourceFile.length))
        let clampedEnd = max(clampedStart, min(endFrame, sourceFile.length))
        guard clampedEnd > clampedStart else {
            throw MeetingSplitAudioExportError.writeFailed("requested slice is empty after clamping")
        }
        sourceFile.framePosition = clampedStart

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw MeetingSplitAudioExportError.writeFailed(
                "unable to open \(destinationURL.lastPathComponent) for writing: \(error)")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCapacity) else {
            throw MeetingSplitAudioExportError.writeFailed("buffer allocation failed")
        }

        var remaining = clampedEnd - clampedStart
        var chunkIndex = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let toRead = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunkFrameCapacity)))
            do {
                try sourceFile.read(into: buffer, frameCount: toRead)
            } catch {
                throw MeetingSplitAudioExportError.sourceUnreadable(sourceURL.lastPathComponent)
            }
            guard buffer.frameLength > 0 else { break }
            do {
                try outputFile.write(from: buffer)
            } catch {
                throw MeetingSplitAudioExportError.writeFailed(
                    "write failed for \(destinationURL.lastPathComponent): \(error)")
            }
            remaining -= AVAudioFramePosition(buffer.frameLength)
            chunkIndex += 1
            afterEachChunk?(chunkIndex)
        }
        // A zero-length read ends the loop above even when `remaining > 0`;
        // that alone must never be treated as a successful, silently shorter
        // export. Prove the exact requested frame count was written before
        // this is reported as a success.
        guard remaining == 0 else {
            throw MeetingSplitAudioExportError.truncatedOutput(
                fileName: destinationURL.lastPathComponent,
                expectedFrames: Int64(clampedEnd - clampedStart),
                actualFrames: Int64(clampedEnd - clampedStart - remaining)
            )
        }
    }

    // MARK: - Source identity (cheap change detection, not a full re-decode)

    private struct SourceIdentity: Equatable {
        let size: Int64
        let modifiedAt: Date?
    }

    private func identity(of url: URL) throws -> SourceIdentity {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.int64Value
        else {
            throw MeetingSplitAudioExportError.sourceUnreadable(url.lastPathComponent)
        }
        return SourceIdentity(size: size, modifiedAt: attributes[.modificationDate] as? Date)
    }

    // MARK: - Storage preflight

    private func preflightStorage(
        sourceURLs: [URL],
        identities: [URL: SourceIdentity],
        playbackURL: URL,
        extents: [URL: DecodedExtent],
        children: [MeetingSplitAudioChildRequest]
    ) throws {
        // Estimate proportionally from the actual requested coverage rather
        // than the worst case of every child costing a full source copy:
        // splitting one recording into N contiguous parts costs roughly one
        // more copy of the covered audio, not N copies of the whole thing.
        let totalSourceDurationMs = Int(
            (Double(extents[playbackURL]?.frameCount ?? 0) / (extents[playbackURL]?.sampleRate ?? 1) * 1_000)
                .rounded())
        let totalRequestedMs = children.reduce(into: 0) { $0 += max(0, $1.range.endMs - $1.range.startMs) }
        let coverageFraction: Double =
            totalSourceDurationMs > 0
            ? min(4, Double(totalRequestedMs) / Double(totalSourceDurationMs))
            : 1
        let perSourceEstimate = sourceURLs.reduce(into: Int64(0)) { total, url in
            total += identities[url]?.size ?? 0
        }
        let estimatedBytes =
            Int64((Double(perSourceEstimate) * coverageFraction * Self.storageSafetyFactor).rounded(.up))
            + Self.storageFixedOverheadBytes

        var checkedVolumes: Set<String> = []
        for child in children {
            let volumeKey = child.destinationFolderURL.standardizedFileURL.path
            guard checkedVolumes.insert(volumeKey).inserted else { continue }
            let available = try availableCapacityBytes(child.destinationFolderURL)
            guard available >= estimatedBytes else {
                throw MeetingSplitAudioExportError.insufficientStorage(
                    estimatedBytes: estimatedBytes, availableBytes: available)
            }
        }
    }

    private static func defaultAvailableCapacity(at url: URL, fileManager: FileManager) throws -> Int64 {
        var candidate = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        while !fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        let values = try candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 else {
            throw MeetingSplitAudioExportError.sourceUnreadable("unable to determine available storage")
        }
        return capacity
    }
}
