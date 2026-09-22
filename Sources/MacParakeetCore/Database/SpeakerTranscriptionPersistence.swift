import Foundation
import GRDB

/// Voiceprint children must copy the parent's SQLite value: supported older
/// transcriptions use UUID text, while current Codable records use UUID blobs.
enum SpeakerTranscriptionPersistence {
    static func key(_ id: UUID, in db: Database) throws -> DatabaseValue {
        if let row = try Row.fetchOne(db, sql: "SELECT id FROM transcriptions WHERE id = ?", arguments: [id]) {
            return row["id"]
        }
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT id FROM transcriptions WHERE typeof(id) = 'text' AND id = ? COLLATE NOCASE",
            arguments: [id.uuidString]
        ) {
            return row["id"]
        }
        // Reads of a missing recording stay empty; writes still fail their FK.
        return id.databaseValue
    }
}

/// Keeps each record's ordinary GRDB encoding, replacing only its resolved FK.
struct SpeakerTranscriptionRecord<Record: PersistableRecord>: PersistableRecord {
    static var databaseTableName: String { Record.databaseTableName }

    let record: Record
    let column: String
    let transcriptionKey: DatabaseValue

    func encode(to container: inout PersistenceContainer) throws {
        try record.encode(to: &container)
        container[column] = transcriptionKey
    }
}
