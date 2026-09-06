import ArgumentParser
import Foundation
import MacParakeetCore

extension MeetingsCommand {
    struct TypesSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "types",
            abstract: "Manage primary meeting types.",
            subcommands: [List.self, Add.self, Rename.self, Archive.self]
        )

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "list")
            @Flag(name: .long, help: "Include archived types.") var includeArchived = false
            @Flag(name: .long, help: "Emit JSON.") var json = false
            @Option var database: String?

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let db = try makeDatabaseManager(database: database)
                    let values = try MeetingTypeRepository(dbQueue: db.dbQueue)
                        .fetchAll(includeArchived: includeArchived)
                    if json { try printJSON(values) }
                    else if values.isEmpty { print("No meeting types found.") }
                    else { values.forEach { print("\($0.id.uuidString.prefix(8))  \($0.name)\($0.isArchived ? "  [archived]" : "")") } }
                }
            }
        }

        struct Add: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "add")
            @Option(name: .long, help: "Type name.") var name: String
            @Option(name: .long, help: "Optional color token.") var color: String?
            @Option(name: .long, help: "Optional SF Symbol name.") var icon: String?
            @Flag(name: .long, help: "Emit JSON.") var json = false
            @Option var database: String?

            func validate() throws {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError("--name must not be empty")
                }
            }

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let db = try makeDatabaseManager(database: database)
                    let repo = MeetingTypeRepository(dbQueue: db.dbQueue)
                    let value = MeetingType(name: name, colorToken: color, iconName: icon)
                    try repo.save(value)
                    let stored = try repo.fetch(id: value.id) ?? value
                    if json { try printJSON(stored) }
                    else { print("Added meeting type '\(stored.name)' (\(stored.id.uuidString.prefix(8))).") }
                }
            }
        }

        struct Rename: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "rename")
            @Argument(help: "Type UUID, prefix, or exact name.") var type: String
            @Option(name: .long, help: "New name.") var name: String
            @Flag(name: .long, help: "Emit JSON.") var json = false
            @Option var database: String?

            func validate() throws {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError("--name must not be empty")
                }
            }

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let db = try makeDatabaseManager(database: database)
                    let repo = MeetingTypeRepository(dbQueue: db.dbQueue)
                    var value = try findMeetingType(type, repo: repo, includeArchived: true)
                    value.name = name
                    value.updatedAt = Date()
                    try repo.save(value)
                    let stored = try repo.fetch(id: value.id) ?? value
                    if json { try printJSON(stored) }
                    else { print("Renamed meeting type to '\(stored.name)'.") }
                }
            }
        }

        struct Archive: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "archive")
            @Argument(help: "Type UUID, prefix, or exact name.") var type: String
            @Flag(name: .long, help: "Restore an archived type.") var restore = false
            @Flag(name: .long, help: "Emit JSON.") var json = false
            @Option var database: String?

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let db = try makeDatabaseManager(database: database)
                    let repo = MeetingTypeRepository(dbQueue: db.dbQueue)
                    var value = try findMeetingType(type, repo: repo, includeArchived: true)
                    try repo.setArchived(id: value.id, isArchived: !restore)
                    value.isArchived = !restore
                    value.updatedAt = Date()
                    if json { try printJSON(value) }
                    else { print("\(restore ? "Restored" : "Archived") meeting type '\(value.name)'.") }
                }
            }
        }
    }

    struct LabelsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "labels",
            abstract: "Manage reusable meeting labels.",
            subcommands: [List.self, Add.self, Rename.self, Archive.self]
        )

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "list")
            @Flag(name: .long, help: "Include archived labels.") var includeArchived = false
            @Flag(name: .long, help: "Emit JSON.") var json = false
            @Option var database: String?

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let db = try makeDatabaseManager(database: database)
                    let values = try MeetingLabelRepository(dbQueue: db.dbQueue)
                        .fetchAll(includeArchived: includeArchived)
                    if json { try printJSON(values) }
                    else if values.isEmpty { print("No meeting labels found.") }
                    else { values.forEach { print("\($0.id.uuidString.prefix(8))  \($0.name)\($0.isArchived ? "  [archived]" : "")") } }
                }
            }
        }

        struct Add: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "add")
            @Option(name: .long, help: "Label name.") var name: String
            @Option(name: .long, help: "Optional color token.") var color: String?
            @Flag(name: .long, help: "Emit JSON.") var json = false
            @Option var database: String?

            func validate() throws {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError("--name must not be empty")
                }
            }

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let db = try makeDatabaseManager(database: database)
                    let repo = MeetingLabelRepository(dbQueue: db.dbQueue)
                    let value = MeetingLabel(name: name, colorToken: color)
                    try repo.save(value)
                    let stored = try repo.fetch(id: value.id) ?? value
                    if json { try printJSON(stored) }
                    else { print("Added meeting label '\(stored.name)' (\(stored.id.uuidString.prefix(8))).") }
                }
            }
        }

        struct Rename: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "rename")
            @Argument(help: "Label UUID, prefix, or exact name.") var label: String
            @Option(name: .long, help: "New name.") var name: String
            @Flag(name: .long, help: "Emit JSON.") var json = false
            @Option var database: String?

            func validate() throws {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError("--name must not be empty")
                }
            }

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let db = try makeDatabaseManager(database: database)
                    let repo = MeetingLabelRepository(dbQueue: db.dbQueue)
                    var value = try findMeetingLabel(label, repo: repo, includeArchived: true)
                    value.name = name
                    value.updatedAt = Date()
                    try repo.save(value)
                    let stored = try repo.fetch(id: value.id) ?? value
                    if json { try printJSON(stored) }
                    else { print("Renamed meeting label to '\(stored.name)'.") }
                }
            }
        }

        struct Archive: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "archive")
            @Argument(help: "Label UUID, prefix, or exact name.") var label: String
            @Flag(name: .long, help: "Restore an archived label.") var restore = false
            @Flag(name: .long, help: "Emit JSON.") var json = false
            @Option var database: String?
            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let db = try makeDatabaseManager(database: database)
                    let repo = MeetingLabelRepository(dbQueue: db.dbQueue)
                    var value = try findMeetingLabel(label, repo: repo, includeArchived: true)
                    try repo.setArchived(id: value.id, isArchived: !restore)
                    value.isArchived = !restore
                    value.updatedAt = Date()
                    if json { try printJSON(value) }
                    else { print("\(restore ? "Restored" : "Archived") meeting label '\(value.name)'.") }
                }
            }
        }
    }

    struct ClassifySubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "classify",
            abstract: "Set a meeting type and add or remove labels atomically."
        )

        @Argument(help: "Meeting UUID, prefix, or exact title.") var meeting: String
        @Option(name: .long, help: "Type UUID/name, or 'none' to clear it.") var type: String?
        @Option(name: .long, help: "Label UUID/name to add; repeatable.") var addLabel: [String] = []
        @Option(name: .long, help: "Label UUID/name to remove; repeatable.") var removeLabel: [String] = []
        @Flag(name: .long, help: "Emit JSON.") var json = false
        @Option var database: String?

        func validate() throws {
            guard type != nil || !addLabel.isEmpty || !removeLabel.isEmpty else {
                throw ValidationError("specify --type, --add-label, or --remove-label")
            }
        }

        func run() async throws {
            try await emitJSONOrRethrow(json: json) {
                let db = try makeDatabaseManager(database: database)
                let transcriptions = TranscriptionRepository(dbQueue: db.dbQueue)
                let meeting = try findClassifiableMeeting(self.meeting, repo: transcriptions)
                let typeRepo = MeetingTypeRepository(dbQueue: db.dbQueue)
                let labelRepo = MeetingLabelRepository(dbQueue: db.dbQueue)
                let labelLinks = TranscriptionMeetingLabelRepository(dbQueue: db.dbQueue)
                let currentType = meeting.meetingTypeId
                let requestedType: UUID? = try type.map { value in
                    value.lowercased() == "none" ? nil : try findMeetingType(value, repo: typeRepo).id
                } ?? currentType
                var labels = try labelLinks.labelIDs(for: meeting.id)
                for value in addLabel { labels.insert(try findMeetingLabel(value, repo: labelRepo).id) }
                for value in removeLabel { labels.remove(try findMeetingLabel(value, repo: labelRepo, includeArchived: true).id) }
                let refresher = MeetingArtifactClassificationRefresher(
                    promptResultRepository: PromptResultRepository(dbQueue: db.dbQueue),
                    artifactStore: MeetingArtifactStore(
                        speakerAttributionReader: SpeakerAttributionReadService(dbQueue: db.dbQueue)
                    )
                )
                let service = MeetingClassificationService(dbQueue: db.dbQueue, artifactRefresher: refresher)
                try await service.update(meetingTypeId: requestedType, labelIds: labels, for: meeting.id)
                let classification = try service.classification(for: meeting.id)
                let record = MeetingClassificationRecord(meetingId: meeting.id, classification: classification)
                if json { try printJSON(record) }
                else {
                    print("Classified '\(meeting.fileName)': type \(classification.meetingType?.name ?? "none"), \(classification.labels.count) label(s).")
                }
            }
        }
    }
}

struct MeetingClassificationRecord: Encodable {
    let meetingId: UUID
    let meetingType: MeetingType?
    let meetingLabels: [MeetingLabel]

    init(meetingId: UUID, classification: MeetingClassification) {
        self.meetingId = meetingId
        meetingType = classification.meetingType
        meetingLabels = classification.labels
    }
}

func findMeetingType(
    _ value: String,
    repo: MeetingTypeRepositoryProtocol,
    includeArchived: Bool = false
) throws -> MeetingType {
    try findClassificationValue(value, values: repo.fetchAll(includeArchived: includeArchived), noun: "meeting type")
}

func findMeetingLabel(
    _ value: String,
    repo: MeetingLabelRepositoryProtocol,
    includeArchived: Bool = false
) throws -> MeetingLabel {
    try findClassificationValue(value, values: repo.fetchAll(includeArchived: includeArchived), noun: "meeting label")
}

private func findClassificationValue<Value: Identifiable>(
    _ input: String,
    values: [Value],
    noun: String
) throws -> Value where Value.ID == UUID {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CLILookupError.emptyID }
    if let uuid = UUID(uuidString: trimmed), let found = values.first(where: { $0.id == uuid }) { return found }
    if let prefix = uuidPrefixSearchKey(trimmed) {
        let matches = values.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw CLILookupError.ambiguous("Multiple \(noun)s match '\(trimmed)'.") }
    }
    let names = values.filter { String(describing: $0).isEmpty == false }.filter {
        if let value = $0 as? MeetingType { return value.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if let value = $0 as? MeetingLabel { return value.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        return false
    }
    if names.count == 1 { return names[0] }
    if names.count > 1 { throw CLILookupError.ambiguous("Multiple \(noun)s named '\(trimmed)'.") }
    if let error = shortUUIDPrefixErrorIfApplicable(trimmed) { throw error }
    throw CLILookupError.notFound("No \(noun) matching '\(trimmed)'.")
}

private func findClassifiableMeeting(_ input: String, repo: TranscriptionRepository) throws -> Transcription {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CLILookupError.emptyID }
    let values = try repo.fetchAll().filter { $0.sourceType == .meeting }
    if let uuid = UUID(uuidString: trimmed), let found = values.first(where: { $0.id == uuid }) { return found }
    if let prefix = uuidPrefixSearchKey(trimmed) {
        let matches = values.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw CLILookupError.ambiguous("Multiple meetings match '\(trimmed)'.") }
    }
    let matches = values.filter { $0.fileName.caseInsensitiveCompare(trimmed) == .orderedSame }
    if matches.count == 1 { return matches[0] }
    if matches.count > 1 { throw CLILookupError.ambiguous("Multiple meetings named '\(trimmed)'.") }
    if let error = shortUUIDPrefixErrorIfApplicable(trimmed) { throw error }
    throw CLILookupError.notFound("No meeting matching '\(trimmed)'.")
}
