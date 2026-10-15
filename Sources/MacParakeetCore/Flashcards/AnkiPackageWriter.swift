import CryptoKit
import Foundation
import GRDB

/// Writes `.apkg` packages in Anki's legacy schema-11 format
/// (`collection.anki2`), which every Anki version since 2.1 can import.
///
/// Cards are exported as new cards: FSRS state lives in MacParakeet and Anki
/// starts its own schedule. Deck, note GUID, and tags are preserved, so
/// re-importing into either app updates instead of duplicating.
public struct AnkiPackageWriter: Sendable {
    /// Fixed so repeated exports update the same note type in Anki.
    static let modelId: Int64 = 1_712_000_000_001
    static let modelName = "MacParakeet Basic"

    public init() {}

    public func write(decks: [(deck: FlashcardDeck, cards: [Flashcard])], to destination: URL) throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-apkg-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let collectionURL = workDir.appendingPathComponent("collection.anki2")
        try buildCollection(decks: decks, at: collectionURL)

        var zip = StoredZipBuilder()
        zip.append(name: "collection.anki2", data: try Data(contentsOf: collectionURL))
        zip.append(name: "media", data: Data("{}".utf8))

        let staged = workDir.appendingPathComponent("out.apkg")
        try zip.finalize().write(to: staged)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    // MARK: - Collection

    func buildCollection(decks: [(deck: FlashcardDeck, cards: [Flashcard])], at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        let nowSeconds = Int64(Date().timeIntervalSince1970)
        let nowMs = nowSeconds * 1_000

        var deckJSON: [String: Any] = ["1": Self.deckObject(id: 1, name: "Default", mod: nowSeconds)]
        var deckIds: [UUID: Int64] = [:]
        for (index, entry) in decks.enumerated() {
            let id = nowMs + Int64(index) + 1
            deckIds[entry.deck.id] = id
            deckJSON[String(id)] = Self.deckObject(id: id, name: entry.deck.name, mod: nowSeconds)
        }
        let firstDeck = decks.first.flatMap { deckIds[$0.deck.id] } ?? 1

        try queue.write { db in
            try db.execute(sql: Self.schemaSQL)
            try db.execute(
                sql: """
                    INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                    VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')
                    """,
                arguments: [
                    Self.startOfToday(), nowMs, nowMs,
                    try Self.json(Self.collectionConfig(currentDeck: firstDeck)),
                    try Self.json([String(Self.modelId): Self.modelObject(deckId: firstDeck, mod: nowSeconds)]),
                    try Self.json(deckJSON),
                    try Self.json(["1": Self.deckConfig(mod: nowSeconds)]),
                ]
            )

            var nextId = nowMs
            var position = 0
            for entry in decks {
                guard let deckId = deckIds[entry.deck.id] else { continue }
                for card in entry.cards {
                    nextId += 1
                    position += 1
                    let fields = [card.front, card.back, card.context ?? ""].map(Self.htmlEscaped)
                    let tags = card.tags.map { " \($0.trimmingCharacters(in: .whitespaces)) " } ?? ""
                    try db.execute(
                        sql: """
                            INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                            VALUES (?, ?, ?, ?, -1, ?, ?, ?, ?, 0, '')
                            """,
                        arguments: [
                            nextId, card.ankiGuid, Self.modelId, nowSeconds, tags,
                            fields.joined(separator: "\u{1F}"), card.front, Self.checksum(card.front),
                        ]
                    )
                    // type/queue 0 = new; `due` is the new-card position.
                    try db.execute(
                        sql: """
                            INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor,
                                               reps, lapses, left, odue, odid, flags, data)
                            VALUES (?, ?, ?, 0, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')
                            """,
                        arguments: [nextId, nextId, deckId, nowSeconds, position]
                    )
                }
            }
        }
        try queue.close()
    }

    static let schemaSQL = """
        CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null,
            scm integer not null, ver integer not null, dty integer not null, usn integer not null,
            ls integer not null, conf text not null, models text not null, decks text not null,
            dconf text not null, tags text not null);
        CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null,
            mod integer not null, usn integer not null, tags text not null, flds text not null,
            sfld integer not null, csum integer not null, flags integer not null, data text not null);
        CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null,
            ord integer not null, mod integer not null, usn integer not null, type integer not null,
            queue integer not null, due integer not null, ivl integer not null, factor integer not null,
            reps integer not null, lapses integer not null, left integer not null, odue integer not null,
            odid integer not null, flags integer not null, data text not null);
        CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null,
            ease integer not null, ivl integer not null, lastIvl integer not null, factor integer not null,
            time integer not null, type integer not null);
        CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
        CREATE INDEX ix_notes_usn on notes (usn);
        CREATE INDEX ix_cards_usn on cards (usn);
        CREATE INDEX ix_revlog_usn on revlog (usn);
        CREATE INDEX ix_cards_nid on cards (nid);
        CREATE INDEX ix_cards_sched on cards (did, queue, due);
        CREATE INDEX ix_revlog_cid on revlog (cid);
        CREATE INDEX ix_notes_csum on notes (csum);
        """

    static func modelObject(deckId: Int64, mod: Int64) -> [String: Any] {
        let field: (String, Int) -> [String: Any] = { name, ord in
            ["name": name, "ord": ord, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": []]
        }
        return [
            "id": modelId,
            "name": modelName,
            "type": 0,
            "mod": mod,
            "usn": -1,
            "sortf": 0,
            "did": deckId,
            "tmpls": [
                [
                    "name": "Card 1", "ord": 0,
                    "qfmt": "{{Front}}",
                    "afmt": "{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}{{#Context}}<br><br><i>{{Context}}</i>{{/Context}}",
                    "did": NSNull(), "bqfmt": "", "bafmt": "",
                ]
            ],
            "flds": [field("Front", 0), field("Back", 1), field("Context", 2)],
            "css": ".card { font-family: -apple-system, Arial; font-size: 22px; text-align: center; color: black; background-color: white; }",
            "latexPre": "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
            "latexPost": "\\end{document}",
            "latexsvg": false,
            "req": [[0, "any", [0]]],
            "tags": [],
            "vers": [],
        ]
    }

    static func deckObject(id: Int64, name: String, mod: Int64) -> [String: Any] {
        [
            "id": id, "name": name, "mod": mod, "usn": -1, "desc": "", "dyn": 0, "conf": 1,
            "collapsed": false, "browserCollapsed": false, "extendNew": 0, "extendRev": 0,
            "newToday": [0, 0], "revToday": [0, 0], "lrnToday": [0, 0], "timeToday": [0, 0],
        ]
    }

    static func deckConfig(mod: Int64) -> [String: Any] {
        [
            "id": 1, "name": "Default", "mod": mod, "usn": 0, "maxTaken": 60, "autoplay": true,
            "timer": 0, "replayq": true, "dyn": false,
            "new": [
                "delays": [1, 10], "ints": [1, 4, 0], "initialFactor": 2500, "order": 1, "perDay": 20,
                "bury": false,
            ],
            "rev": ["perDay": 200, "ease4": 1.3, "ivlFct": 1, "maxIvl": 36500, "bury": false, "hardFactor": 1.2],
            "lapse": ["delays": [10], "mult": 0, "minInt": 1, "leechFails": 8, "leechAction": 1],
        ]
    }

    static func collectionConfig(currentDeck: Int64) -> [String: Any] {
        [
            "nextPos": 1, "estTimes": true, "activeDecks": [1], "sortType": "noteFld", "timeLim": 0,
            "sortBackwards": false, "addToCur": true, "curDeck": currentDeck, "newSpread": 0,
            "dueCounts": true, "curModel": modelId, "collapseTime": 1200,
        ]
    }

    static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Anki's duplicate-check checksum: first 8 hex digits of SHA-1 of the
    /// stripped sort field.
    static func checksum(_ text: String) -> Int64 {
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return digest.prefix(4).reduce(Int64(0)) { $0 << 8 | Int64($1) }
    }

    static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func startOfToday() -> Int64 {
        Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
    }
}

/// Minimal ZIP writer using the "stored" method (no compression), which
/// Anki accepts. Ported from LinguaBrain-AI's `ZIPArchiveBuilder`.
struct StoredZipBuilder {
    private struct Entry {
        let name: Data
        let size: UInt32
        let crc: UInt32
        let offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []

    mutating func append(name: String, data payload: Data) {
        let nameData = Data(name.utf8)
        let crc = Self.crc32(payload)
        let offset = UInt32(data.count)
        data.appendLE(UInt32(0x0403_4B50))
        data.appendLE(UInt16(20))
        data.appendLE(UInt16(0))  // flags
        data.appendLE(UInt16(0))  // stored
        data.appendLE(UInt16(0))  // time
        data.appendLE(UInt16(0x21))  // date: 1980-01-01
        data.appendLE(crc)
        data.appendLE(UInt32(payload.count))
        data.appendLE(UInt32(payload.count))
        data.appendLE(UInt16(nameData.count))
        data.appendLE(UInt16(0))
        data.append(nameData)
        data.append(payload)
        entries.append(Entry(name: nameData, size: UInt32(payload.count), crc: crc, offset: offset))
    }

    func finalize() -> Data {
        var result = data
        let centralOffset = UInt32(result.count)
        for entry in entries {
            result.appendLE(UInt32(0x0201_4B50))
            result.appendLE(UInt16(20))
            result.appendLE(UInt16(20))
            result.appendLE(UInt16(0))
            result.appendLE(UInt16(0))
            result.appendLE(UInt16(0))
            result.appendLE(UInt16(0x21))
            result.appendLE(entry.crc)
            result.appendLE(entry.size)
            result.appendLE(entry.size)
            result.appendLE(UInt16(entry.name.count))
            result.appendLE(UInt16(0))
            result.appendLE(UInt16(0))
            result.appendLE(UInt16(0))
            result.appendLE(UInt16(0))
            result.appendLE(UInt32(0))
            result.appendLE(entry.offset)
            result.append(entry.name)
        }
        let centralSize = UInt32(result.count) - centralOffset
        result.appendLE(UInt32(0x0605_4B50))
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(entries.count))
        result.appendLE(UInt16(entries.count))
        result.appendLE(centralSize)
        result.appendLE(centralOffset)
        result.appendLE(UInt16(0))
        return result
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    fileprivate mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
