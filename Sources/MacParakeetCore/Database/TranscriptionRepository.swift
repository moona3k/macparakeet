import Foundation
import GRDB

public protocol TranscriptionRepositoryProtocol: Sendable {
    func save(_ transcription: Transcription) throws
    func fetch(id: UUID) throws -> Transcription?
    func fetchAll(limit: Int?) throws -> [Transcription]
    func fetchLibraryPage(query: TranscriptionLibraryQuery) throws -> TranscriptionLibraryPage
    func fetchByFilePath(_ filePath: String, sourceType: Transcription.SourceType?) throws -> [Transcription]
    func fetchMeetingAudioRetentionCandidates(createdAtOrBefore cutoff: Date) throws -> [Transcription]
    func fetchCompletedByVideoID(_ videoID: String) throws -> Transcription?
    func count() throws -> Int
    func search(query: String, limit: Int?) throws -> [Transcription]
    func delete(id: UUID) throws -> Bool
    func deleteAll() throws
    func updateStatus(id: UUID, status: Transcription.TranscriptionStatus, errorMessage: String?) throws
    func updateFileName(id: UUID, fileName: String) throws
    func updateChatMessages(id: UUID, chatMessages: [ChatMessage]?) throws
    func updateSpeakers(id: UUID, speakers: [SpeakerInfo]?) throws
    func updateFilePath(id: UUID, filePath: String?) throws
    func updateMeetingArtifactFolderPath(id: UUID, folderPath: String?) throws
    func clearStoredAudioPathsForURLTranscriptions() throws
    func clearStoredAudioPathsForMeetingTranscriptions(under directoryPath: String) throws
    func updateFavorite(id: UUID, isFavorite: Bool) throws
    func fetchFavorites() throws -> [Transcription]
}

extension TranscriptionRepositoryProtocol {
    public func fetchByFilePath(
        _ filePath: String,
        sourceType: Transcription.SourceType? = nil
    ) throws -> [Transcription] {
        try fetchAll(limit: nil).filter {
            $0.filePath == filePath
                && (sourceType == nil || $0.sourceType == sourceType)
        }
    }

    public func fetchMeetingAudioRetentionCandidates(createdAtOrBefore cutoff: Date) throws -> [Transcription] {
        try fetchAll(limit: nil).filter {
            $0.sourceType == .meeting
                && !($0.filePath?.isEmpty ?? true)
                && $0.status == .completed
                && $0.createdAt <= cutoff
        }
    }

    public func fetchCompletedByVideoID(_ videoID: String) throws -> Transcription? { nil }
    public func count() throws -> Int { try fetchAll(limit: nil).count }
    public func search(query: String, limit: Int?) throws -> [Transcription] { [] }
    public func fetchLibraryPage(query: TranscriptionLibraryQuery) throws -> TranscriptionLibraryPage {
        var results = try fetchAll(limit: nil)

        if !query.includeProcessing {
            results = results.filter { $0.status != .processing }
        }
        if let sourceType = query.sourceType {
            results = results.filter { $0.sourceType == sourceType }
        }
        if query.favoritesOnly {
            results = results.filter(\.isFavorite)
        }
        if let searchText = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !searchText.isEmpty {
            let normalizedQuery = UnicodeSearch.makeKey(searchText)
            results = results.filter { transcription in
                transcriptionMatchesLibrarySearch(transcription, normalizedQuery: normalizedQuery)
            }
        }

        switch query.sortOrder {
        case .dateDescending:
            results.sort { $0.createdAt > $1.createdAt }
        case .dateAscending:
            results.sort { $0.createdAt < $1.createdAt }
        case .titleAscending:
            results.sort {
                $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
            }
        }

        let limit = max(0, query.limit)
        let offset = max(0, query.offset)
        guard offset < results.count else {
            return TranscriptionLibraryPage(items: [], hasMore: false)
        }
        let end = min(results.count, offset + limit)
        return TranscriptionLibraryPage(
            items: Array(results[offset..<end]),
            hasMore: results.count > end
        )
    }
    public func clearStoredAudioPathsForURLTranscriptions() throws {}
    public func clearStoredAudioPathsForMeetingTranscriptions(under directoryPath: String) throws {}
    public func updateFileName(id: UUID, fileName: String) throws {}
    public func updateChatMessages(id: UUID, chatMessages: [ChatMessage]?) throws {}
    public func updateSpeakers(id: UUID, speakers: [SpeakerInfo]?) throws {}
    public func updateFilePath(id: UUID, filePath: String?) throws {}
    public func updateMeetingArtifactFolderPath(id: UUID, folderPath: String?) throws {}
    public func updateFavorite(id: UUID, isFavorite: Bool) throws {}
    public func fetchFavorites() throws -> [Transcription] { [] }
}

// GRDB's DatabaseQueue serializes reads/writes internally, so sharing this
// repository across tasks is intentional even though DatabaseQueue does not
// advertise Swift Sendable conformance.
public final class TranscriptionRepository: TranscriptionRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ transcription: Transcription) throws {
        try dbQueue.write { db in
            try transcription.save(db)
        }
    }

    public func fetch(id: UUID) throws -> Transcription? {
        try dbQueue.read { db in
            try Transcription.fetchOne(db, key: id)
        }
    }

    public func fetchAll(limit: Int? = nil) throws -> [Transcription] {
        try dbQueue.read { db in
            var request = Transcription
                .order(Transcription.Columns.createdAt.desc)
            if let limit {
                request = request.limit(limit)
            }
            return try request.fetchAll(db)
        }
    }

    public func fetchLibraryPage(query: TranscriptionLibraryQuery) throws -> TranscriptionLibraryPage {
        try dbQueue.read { db in
            let limit = max(0, query.limit)
            let offset = max(0, query.offset)
            let fetchLimit = limit == Int.max ? Int.max : limit + 1
            var whereClauses: [String] = []
            var arguments: [any DatabaseValueConvertible] = []

            if !query.includeProcessing {
                whereClauses.append("status != ?")
                arguments.append(Transcription.TranscriptionStatus.processing.rawValue)
            }
            if let sourceType = query.sourceType {
                whereClauses.append("sourceType = ?")
                arguments.append(sourceType.rawValue)
            }
            if query.favoritesOnly {
                whereClauses.append("isFavorite = 1")
            }
            if let searchText = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !searchText.isEmpty {
                return try Self.fetchUnicodeSearchLibraryPage(
                    db: db,
                    whereClauses: whereClauses,
                    arguments: arguments,
                    normalizedQuery: UnicodeSearch.makeKey(searchText),
                    sortOrder: query.sortOrder,
                    limit: limit,
                    offset: offset
                )
            }

            var sql = "SELECT * FROM transcriptions"
            if !whereClauses.isEmpty {
                sql += " WHERE " + whereClauses.joined(separator: " AND ")
            }
            sql += " ORDER BY \(Self.libraryOrderClause(for: query.sortOrder))"
            sql += " LIMIT ? OFFSET ?"
            arguments.append(fetchLimit)
            arguments.append(offset)

            let fetched = try Transcription.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
            return TranscriptionLibraryPage(
                items: limit == 0 ? [] : Array(fetched.prefix(limit)),
                hasMore: fetched.count > limit
            )
        }
    }

    private static func fetchUnicodeSearchLibraryPage(
        db: Database,
        whereClauses: [String],
        arguments: [any DatabaseValueConvertible],
        normalizedQuery: String,
        sortOrder: TranscriptionLibrarySortOrder,
        limit: Int,
        offset: Int
    ) throws -> TranscriptionLibraryPage {
        var sql = "SELECT * FROM transcriptions"
        if !whereClauses.isEmpty {
            sql += " WHERE " + whereClauses.joined(separator: " AND ")
        }
        sql += " ORDER BY \(Self.libraryOrderClause(for: sortOrder))"

        let cursor = try Transcription.fetchCursor(
            db,
            sql: sql,
            arguments: StatementArguments(arguments)
        )
        var skipped = 0
        var items: [Transcription] = []
        while let transcription = try cursor.next() {
            guard transcriptionMatchesLibrarySearch(transcription, normalizedQuery: normalizedQuery) else {
                continue
            }
            if skipped < offset {
                skipped += 1
                continue
            }
            guard items.count < limit else {
                return TranscriptionLibraryPage(items: items, hasMore: true)
            }
            items.append(transcription)
        }
        return TranscriptionLibraryPage(items: items, hasMore: false)
    }

    public func fetchBySourceType(_ sourceType: Transcription.SourceType, limit: Int? = nil) throws -> [Transcription] {
        try dbQueue.read { db in
            var request = Transcription
                .filter(Transcription.Columns.sourceType == sourceType.rawValue)
                .order(Transcription.Columns.createdAt.desc)
            if let limit {
                request = request.limit(limit)
            }
            return try request.fetchAll(db)
        }
    }

    public func fetchByIDPrefix(_ idPrefix: String) throws -> [Transcription] {
        try fetchByIDPrefix(idPrefix, sourceType: nil)
    }

    public func fetchBySourceType(
        _ sourceType: Transcription.SourceType,
        idPrefix: String
    ) throws -> [Transcription] {
        try fetchByIDPrefix(idPrefix, sourceType: sourceType)
    }

    private func fetchByIDPrefix(
        _ idPrefix: String,
        sourceType: Transcription.SourceType?
    ) throws -> [Transcription] {
        let trimmed = idPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let compactPattern = escapedLikePattern(trimmed.lowercased().replacingOccurrences(of: "-", with: "")) + "%"
        var sql = """
            (lower(hex(id)) LIKE ? ESCAPE '\\'
                OR replace(lower(id), '-', '') LIKE ? ESCAPE '\\')
            """
        var arguments: [String] = [compactPattern, compactPattern]
        if let sourceType {
            sql = "sourceType = ? AND \(sql)"
            arguments.insert(sourceType.rawValue, at: 0)
        }
        return try dbQueue.read { db in
            try Transcription
                .filter(sql: sql, arguments: StatementArguments(arguments))
                .order(Transcription.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchByFileName(_ fileName: String) throws -> [Transcription] {
        try fetchByFileName(fileName, sourceType: nil)
    }

    public func fetchBySourceType(
        _ sourceType: Transcription.SourceType,
        fileName: String
    ) throws -> [Transcription] {
        try fetchByFileName(fileName, sourceType: sourceType)
    }

    private func fetchByFileName(
        _ fileName: String,
        sourceType: Transcription.SourceType?
    ) throws -> [Transcription] {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var sql = "lower(fileName) = lower(?)"
        var arguments: [String] = [trimmed]
        if let sourceType {
            sql = "sourceType = ? AND \(sql)"
            arguments.insert(sourceType.rawValue, at: 0)
        }
        return try dbQueue.read { db in
            try Transcription
                .filter(sql: sql, arguments: StatementArguments(arguments))
                .order(Transcription.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchByFilePath(
        _ filePath: String,
        sourceType: Transcription.SourceType? = nil
    ) throws -> [Transcription] {
        try dbQueue.read { db in
            var request = Transcription
                .filter(Transcription.Columns.filePath == filePath)
                .order(Transcription.Columns.createdAt.desc)
            if let sourceType {
                request = request.filter(Transcription.Columns.sourceType == sourceType.rawValue)
            }
            return try request.fetchAll(db)
        }
    }

    public func fetchMeetingAudioRetentionCandidates(createdAtOrBefore cutoff: Date) throws -> [Transcription] {
        try dbQueue.read { db in
            try Transcription
                .filter(Transcription.Columns.sourceType == Transcription.SourceType.meeting.rawValue)
                .filter(Transcription.Columns.filePath != nil)
                .filter(Transcription.Columns.filePath != "")
                .filter(Transcription.Columns.status == Transcription.TranscriptionStatus.completed.rawValue)
                .filter(Transcription.Columns.createdAt <= cutoff)
                .order(Transcription.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try Transcription.fetchCount(db)
        }
    }

    public func search(query: String, limit: Int? = nil) throws -> [Transcription] {
        try dbQueue.read { db in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            let normalizedQuery = UnicodeSearch.makeKey(trimmed)
            let cursor = try Transcription
                .order(Transcription.Columns.createdAt.desc)
                .fetchCursor(db)

            var results: [Transcription] = []
            while let transcription = try cursor.next() {
                guard transcriptionMatchesLibrarySearch(transcription, normalizedQuery: normalizedQuery) else { continue }

                results.append(transcription)
                if let limit, results.count >= limit {
                    break
                }
            }
            return results
        }
    }

    public func fetchCompletedByVideoID(_ videoID: String) throws -> Transcription? {
        let trimmed = videoID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Escape LIKE wildcards (% and _) so video IDs containing _ match literally
        let escaped = trimmed
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")

        return try dbQueue.read { db in
            try Transcription
                .filter(Transcription.Columns.sourceURL != nil)
                .filter(Transcription.Columns.status == Transcription.TranscriptionStatus.completed.rawValue)
                .filter(Transcription.Columns.sourceURL.like("%\(escaped)%", escape: "\\"))
                .order(Transcription.Columns.createdAt.desc)
                .fetchOne(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try Transcription.deleteOne(db, key: id)
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { db in
            _ = try Transcription.deleteAll(db)
        }
    }

    public func updateStatus(
        id: UUID,
        status: Transcription.TranscriptionStatus,
        errorMessage: String? = nil
    ) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id) else { return }
            transcription.status = status
            transcription.errorMessage = errorMessage
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func updateFileName(id: UUID, fileName: String) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id) else { return }
            transcription.fileName = fileName
            // A user-driven rename (meetings only) is the source of truth for
            // the meeting's name. The Library rows already read `fileName` for
            // meetings, but `derivedTitle` still feeds the "Save Audio As…"
            // export-filename helper — mirror the rename into it so the
            // suggested export name follows the new title instead of the stale
            // transcript-content title.
            transcription.derivedTitle = fileName
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func updateChatMessages(id: UUID, chatMessages: [ChatMessage]?) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id) else { return }
            transcription.chatMessages = chatMessages
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func updateSpeakers(id: UUID, speakers: [SpeakerInfo]?) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id) else { return }
            transcription.speakers = speakers
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func updateUserNotes(id: UUID, userNotes: String?) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id) else { return }
            transcription.userNotes = userNotes
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func updateFilePath(id: UUID, filePath: String?) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id) else { return }
            transcription.filePath = filePath
            if transcription.sourceType == .meeting,
               transcription.meetingArtifactFolderPath == nil,
               let filePath,
               let folderPath = Self.artifactFolderPath(forAudioPath: filePath) {
                transcription.meetingArtifactFolderPath = folderPath
            }
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func updateMeetingArtifactFolderPath(id: UUID, folderPath: String?) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id),
                  transcription.sourceType == .meeting else { return }
            transcription.meetingArtifactFolderPath = Self.normalizedPath(folderPath)
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func clearStoredAudioPathsForURLTranscriptions() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE transcriptions SET filePath = NULL WHERE sourceURL IS NOT NULL"
            )
        }
    }

    public func clearStoredAudioPathsForMeetingTranscriptions(under directoryPath: String) throws {
        try dbQueue.write { db in
            let now = Date()
            let meetings = try Transcription
                .filter(Transcription.Columns.sourceType == Transcription.SourceType.meeting.rawValue)
                .fetchAll(db)

            for var transcription in meetings {
                guard let filePath = transcription.filePath,
                      Self.isFilePath(filePath, underDirectory: directoryPath) else {
                    continue
                }
                if transcription.meetingArtifactFolderPath == nil {
                    transcription.meetingArtifactFolderPath = Self.artifactFolderPath(forAudioPath: filePath)
                }
                transcription.filePath = nil
                transcription.updatedAt = now
                try transcription.update(db)
            }
        }
    }

    public func updateFavorite(id: UUID, isFavorite: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE transcriptions SET isFavorite = ?, updatedAt = ? WHERE id = ?",
                arguments: [isFavorite, Date(), id]
            )
        }
    }

    public func fetchFavorites() throws -> [Transcription] {
        try dbQueue.read { db in
            try Transcription
                .filter(Transcription.Columns.isFavorite == true)
                .order(Transcription.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    private static func isFilePath(_ filePath: String, underDirectory directoryPath: String) -> Bool {
        let root = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL.path
        let target = URL(fileURLWithPath: filePath).standardizedFileURL.path
        return target.hasPrefix(root + "/")
    }

    private static func artifactFolderPath(forAudioPath filePath: String) -> String? {
        let trimmed = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private static func libraryOrderClause(for sortOrder: TranscriptionLibrarySortOrder) -> String {
        switch sortOrder {
        case .dateDescending:
            return "createdAt DESC"
        case .dateAscending:
            return "createdAt ASC"
        case .titleAscending:
            return "fileName COLLATE NOCASE ASC, createdAt DESC"
        }
    }
}

private func escapedLikePattern(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
}

private func transcriptionMatchesLibrarySearch(
    _ transcription: Transcription,
    normalizedQuery: String
) -> Bool {
    UnicodeSearch.contains(transcription.fileName, normalizedQuery: normalizedQuery)
        || (transcription.rawTranscript.map { UnicodeSearch.contains($0, normalizedQuery: normalizedQuery) } ?? false)
        || (transcription.cleanTranscript.map { UnicodeSearch.contains($0, normalizedQuery: normalizedQuery) } ?? false)
        || (transcription.channelName.map { UnicodeSearch.contains($0, normalizedQuery: normalizedQuery) } ?? false)
}
