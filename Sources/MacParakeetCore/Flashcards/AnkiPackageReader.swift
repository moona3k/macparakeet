import Compression
import Foundation
import GRDB

/// One card read from an `.apkg`, already reduced to plain text.
public struct AnkiImportedCard: Sendable, Equatable {
    public var deckName: String
    public var guid: String
    public var front: String
    public var back: String
    public var context: String?
    public var tags: String?
}

public enum AnkiPackageError: Error, LocalizedError, Equatable {
    case fileTooLarge
    case malformedArchive
    case unsupportedZip64
    case tooManyEntries
    case unsafePath(String)
    case encryptedEntry(String)
    case unsupportedCompression(String)
    case expandedSizeExceeded
    case suspiciousCompressionRatio(String)
    case missingCollection
    case unsupportedModernCollection
    case malformedCollection
    case noCards

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "This deck file is too large to import."
        case .malformedArchive: return "This file is not a valid Anki package."
        case .unsupportedZip64: return "This Anki package uses ZIP64, which is not supported."
        case .tooManyEntries: return "This Anki package contains too many files."
        case .unsafePath(let path): return "This Anki package contains an unsafe file path: \(path)"
        case .encryptedEntry(let path): return "This Anki package contains an encrypted file: \(path)"
        case .unsupportedCompression(let path): return "This Anki package uses unsupported compression for \(path)."
        case .expandedSizeExceeded: return "This Anki package expands beyond the import size limit."
        case .suspiciousCompressionRatio(let path): return "This Anki package looks unsafe (compression ratio of \(path))."
        case .missingCollection: return "This Anki package has no card collection."
        case .unsupportedModernCollection:
            return "This deck uses Anki's newest package format. In Anki, export again with “Support older Anki versions” turned on."
        case .malformedCollection: return "The card collection inside this Anki package is damaged."
        case .noCards: return "This Anki package contains no cards."
        }
    }
}

/// Reads `.apkg` deck packages. Packages are untrusted input: the ZIP is
/// validated before anything is extracted, only the collection database is
/// expanded, and it is opened read-only. Media is not imported.
///
/// Ported from LinguaBrain-AI's `APKGInspector`/`APKGCardReader`.
public struct AnkiPackageReader: Sendable {
    let maximumArchiveBytes: UInt64 = 512 * 1_024 * 1_024
    let maximumEntryBytes: UInt64 = 512 * 1_024 * 1_024
    let maximumExpandedBytes: UInt64 = 1_024 * 1_024 * 1_024
    let maximumEntries = 50_000
    let maximumCompressionRatio: UInt64 = 200
    let maximumCards = 100_000

    public init() {}

    public func readCards(at url: URL) throws -> [AnkiImportedCard] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries = try centralDirectory(of: data)

        let names = Set(entries.map(\.name))
        // Modern exports also carry a placeholder `collection.anki2` that only
        // says "please update Anki", so its presence is not enough.
        if names.contains("collection.anki21b") && !names.contains("collection.anki21") {
            throw AnkiPackageError.unsupportedModernCollection
        }
        guard let entry = entries.first(where: { $0.name == "collection.anki21" })
            ?? entries.first(where: { $0.name == "collection.anki2" })
        else {
            throw AnkiPackageError.missingCollection
        }

        let database = try extract(entry, from: data)
        guard database.starts(with: Data("SQLite format 3\0".utf8)) else {
            throw AnkiPackageError.malformedCollection
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-apkg-\(UUID().uuidString).sqlite")
        try database.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let cards = try readCollection(at: tempURL)
        guard !cards.isEmpty else { throw AnkiPackageError.noCards }
        return cards
    }

    // MARK: - ZIP

    struct Entry: Equatable {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let expandedSize: Int
        let localHeaderOffset: Int
    }

    func centralDirectory(of data: Data) throws -> [Entry] {
        guard UInt64(data.count) <= maximumArchiveBytes else { throw AnkiPackageError.fileTooLarge }
        let tailStart = max(0, data.count - 65_557)
        guard let eocd = lastIndex(of: 0x0605_4B50, in: data, from: tailStart), eocd + 22 <= data.count else {
            throw AnkiPackageError.malformedArchive
        }
        let entryCount = data.ankiUInt16LE(at: eocd + 10)
        let centralSize = data.ankiUInt32LE(at: eocd + 12)
        let centralOffset = data.ankiUInt32LE(at: eocd + 16)
        guard data.ankiUInt16LE(at: eocd + 4) == 0, data.ankiUInt16LE(at: eocd + 6) == 0,
            data.ankiUInt16LE(at: eocd + 8) == entryCount
        else { throw AnkiPackageError.malformedArchive }
        guard entryCount != .max, centralSize != .max, centralOffset != .max else {
            throw AnkiPackageError.unsupportedZip64
        }
        guard Int(entryCount) <= maximumEntries else { throw AnkiPackageError.tooManyEntries }
        guard Int(centralOffset) + Int(centralSize) <= data.count else { throw AnkiPackageError.malformedArchive }

        var cursor = Int(centralOffset)
        let end = cursor + Int(centralSize)
        var expandedTotal: UInt64 = 0
        var seen = Set<String>()
        var entries: [Entry] = []

        for _ in 0..<Int(entryCount) {
            guard cursor + 46 <= end, data.ankiUInt32LE(at: cursor) == 0x0201_4B50 else {
                throw AnkiPackageError.malformedArchive
            }
            let flags = data.ankiUInt16LE(at: cursor + 8)
            let method = data.ankiUInt16LE(at: cursor + 10)
            let compressed = UInt64(data.ankiUInt32LE(at: cursor + 20))
            let expanded = UInt64(data.ankiUInt32LE(at: cursor + 24))
            let nameLength = Int(data.ankiUInt16LE(at: cursor + 28))
            let extraLength = Int(data.ankiUInt16LE(at: cursor + 30))
            let commentLength = Int(data.ankiUInt16LE(at: cursor + 32))
            let externalAttributes = data.ankiUInt32LE(at: cursor + 38)
            let localOffset = Int(data.ankiUInt32LE(at: cursor + 42))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, next <= end,
                let name = String(data: data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)), encoding: .utf8)
            else { throw AnkiPackageError.malformedArchive }

            try validatePath(name)
            guard seen.insert(name).inserted else { throw AnkiPackageError.malformedArchive }
            guard flags & 0x1 == 0 else { throw AnkiPackageError.encryptedEntry(name) }
            guard method == 0 || method == 8 else { throw AnkiPackageError.unsupportedCompression(name) }
            guard (externalAttributes >> 16) & 0xF000 != 0xA000 else { throw AnkiPackageError.unsafePath(name) }
            guard expanded <= maximumEntryBytes else { throw AnkiPackageError.expandedSizeExceeded }
            expandedTotal += expanded
            guard expandedTotal <= maximumExpandedBytes else { throw AnkiPackageError.expandedSizeExceeded }
            if compressed == 0, expanded > 0 { throw AnkiPackageError.suspiciousCompressionRatio(name) }
            if compressed > 0, expanded / compressed > maximumCompressionRatio {
                throw AnkiPackageError.suspiciousCompressionRatio(name)
            }

            entries.append(
                Entry(
                    name: name,
                    method: method,
                    compressedSize: Int(compressed),
                    expandedSize: Int(expanded),
                    localHeaderOffset: localOffset
                ))
            cursor = next
        }
        return entries
    }

    func extract(_ entry: Entry, from data: Data) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.ankiUInt32LE(at: header) == 0x0403_4B50 else {
            throw AnkiPackageError.malformedCollection
        }
        let start = header + 30 + Int(data.ankiUInt16LE(at: header + 26)) + Int(data.ankiUInt16LE(at: header + 28))
        guard start + entry.compressedSize <= data.count else { throw AnkiPackageError.malformedCollection }
        let payload = data.subdata(in: start..<(start + entry.compressedSize))

        switch entry.method {
        case 0:
            guard payload.count == entry.expandedSize else { throw AnkiPackageError.malformedCollection }
            return payload
        case 8:
            return try inflateRaw(payload, expandedSize: entry.expandedSize)
        default:
            throw AnkiPackageError.unsupportedCompression(entry.name)
        }
    }

    /// `COMPRESSION_ZLIB` in Apple's Compression framework is raw DEFLATE,
    /// which is exactly what ZIP method 8 stores.
    private func inflateRaw(_ input: Data, expandedSize: Int) throws -> Data {
        guard expandedSize > 0 else { return Data() }
        var output = Data(count: expandedSize)
        let written = output.withUnsafeMutableBytes { outBuffer in
            input.withUnsafeBytes { inBuffer in
                compression_decode_buffer(
                    outBuffer.bindMemory(to: UInt8.self).baseAddress!, expandedSize,
                    inBuffer.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expandedSize else { throw AnkiPackageError.malformedCollection }
        return output
    }

    private func validatePath(_ name: String) throws {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.hasPrefix("/"), !normalized.hasPrefix("~"), !normalized.contains(":"),
            !components.contains(".."), !components.contains(".")
        else { throw AnkiPackageError.unsafePath(name) }
    }

    private func lastIndex(of signature: UInt32, in data: Data, from lowerBound: Int) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = data.count - 4
        while index >= lowerBound {
            if data.ankiUInt32LE(at: index) == signature { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - Collection

    func readCollection(at url: URL) throws -> [AnkiImportedCard] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            throw AnkiPackageError.malformedCollection
        }

        return try queue.read { db in
            let colColumns = Set(try db.columns(in: "col").map(\.name))
            if !colColumns.contains("models") {
                return try readLinguaBrainCollection(db)
            }
            guard let col = try Row.fetchOne(db, sql: "SELECT models, decks FROM col LIMIT 1") else {
                throw AnkiPackageError.malformedCollection
            }
            let fieldNames = Self.modelFieldNames(json: col["models"] as String? ?? "{}")
            let deckNames = Self.deckNames(json: col["decks"] as String? ?? "{}")

            // One card per note: Anki generates several cards (e.g. reversed)
            // from one note, but they share the same text.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT n.guid, n.mid, n.flds, n.tags, MIN(c.did) AS did
                    FROM notes n JOIN cards c ON c.nid = n.id
                    GROUP BY n.id ORDER BY n.id LIMIT ?
                    """,
                arguments: [maximumCards]
            )

            return rows.compactMap { row -> AnkiImportedCard? in
                let modelId: Int64 = row["mid"]
                let deckId: Int64 = row["did"]
                let rawFields = (row["flds"] as String? ?? "")
                    .split(separator: "\u{1F}", omittingEmptySubsequences: false)
                    .map(String.init)
                let names = fieldNames[String(modelId)] ?? []
                return Self.mapCard(
                    fields: rawFields,
                    names: names,
                    guid: row["guid"],
                    tags: (row["tags"] as String?)?.trimmingCharacters(in: .whitespaces),
                    deckName: deckNames[String(deckId)] ?? "Imported"
                )
            }
        }
    }

    /// Packages written by LinguaBrain-AI's exporter keep models and decks in
    /// their own tables and note fields as a JSON array.
    private func readLinguaBrainCollection(_ db: Database) throws -> [AnkiImportedCard] {
        var fieldNames: [Int64: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, fields FROM models") {
            fieldNames[row["id"]] = (row["fields"] as String? ?? "").split(separator: ",").map(String.init)
        }
        var deckNames: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, name FROM decks") {
            deckNames[row["id"]] = row["name"]
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT n.guid, n.mid, n.fields, n.tags, MIN(c.did) AS did
                FROM notes n JOIN cards c ON c.nid = n.id
                GROUP BY n.id ORDER BY n.id LIMIT ?
                """,
            arguments: [maximumCards]
        )
        return rows.compactMap { row -> AnkiImportedCard? in
            let raw = row["fields"] as String? ?? "[]"
            guard let data = raw.data(using: .utf8),
                let fields = try? JSONDecoder().decode([String].self, from: data)
            else { return nil }
            let tags = (row["tags"] as String?)?.replacingOccurrences(of: ",", with: " ")
            return Self.mapCard(
                fields: fields,
                names: fieldNames[row["mid"]] ?? [],
                guid: row["guid"],
                tags: tags,
                deckName: deckNames[row["did"]] ?? "Imported"
            )
        }
    }

    static func mapCard(fields: [String], names: [String], guid: String, tags: String?, deckName: String)
        -> AnkiImportedCard?
    {
        var named: [String: String] = [:]
        for (name, value) in zip(names, fields) { named[name.lowercased()] = value }

        func pick(_ keys: [String], fallbackIndex: Int) -> String {
            for key in keys { if let value = named[key] { return value } }
            return fields.indices.contains(fallbackIndex) ? fields[fallbackIndex] : ""
        }

        let front = plainText(pick(["front", "question", "word", "text"], fallbackIndex: 0))
        let back = plainText(pick(["back", "answer", "meaning", "definition", "translation"], fallbackIndex: 1))
        let contextKeys = ["context", "example", "sentence", "extra", "back extra"]
        let context = contextKeys.compactMap { named[$0] }.map(plainText).first { !$0.isEmpty }
        guard !front.isEmpty else { return nil }
        return AnkiImportedCard(
            deckName: deckName,
            guid: guid,
            front: front,
            back: back.isEmpty ? "—" : back,
            context: context,
            tags: (tags?.isEmpty ?? true) ? nil : tags
        )
    }

    static func modelFieldNames(json: String) -> [String: [String]] {
        guard let data = json.data(using: .utf8),
            let models = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        return models.mapValues { model in
            let fields = model["flds"] as? [[String: Any]] ?? []
            return fields
                .sorted { ($0["ord"] as? Int ?? 0) < ($1["ord"] as? Int ?? 0) }
                .compactMap { $0["name"] as? String }
        }
    }

    static func deckNames(json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
            let decks = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        return decks.compactMapValues { $0["name"] as? String }
    }

    /// Strips Anki HTML, sound tags, and entities down to readable text.
    static func plainText(_ html: String) -> String {
        var result = html
            .replacingOccurrences(of: #"\[sound:[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</div>|</p>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
            .components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

extension Data {
    func ankiUInt16LE(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func ankiUInt32LE(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }
}
