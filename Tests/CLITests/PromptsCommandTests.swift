import Foundation
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class PromptsCommandTests: XCTestCase {

    func testVersionCommandsParse() throws {
        let show = try PromptsCommand.ShowSubcommand.parse(["Prompt", "--version", "2", "--json"])
        XCTAssertEqual(show.version, 2)
        XCTAssertNoThrow(try PromptsCommand.HistorySubcommand.parse(["Prompt", "--json"]))
        let diff = try PromptsCommand.DiffSubcommand.parse(["Prompt", "--from", "1", "--to", "2", "--json"])
        XCTAssertEqual(diff.from, 1)
        XCTAssertEqual(diff.to, 2)
        XCTAssertNoThrow(try PromptsCommand.RestoreSubcommand.parse(["Prompt", "--version", "1", "--json"]))
        XCTAssertNoThrow(try PromptsCommand.RestoreDeletedSubcommand.parse(["Prompt", "--json"]))
    }

    func testVersionCommandsRejectInvalidNumbers() {
        XCTAssertThrowsError(try PromptsCommand.DiffSubcommand.parse(["Prompt", "--from", "0", "--to", "2"]))
        XCTAssertThrowsError(try PromptsCommand.RestoreSubcommand.parse(["Prompt", "--version", "0"]))
    }

    func testHistoryDiffAndRestoreRoundTrip() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-cli-versions-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let database = try DatabaseManager(path: databaseURL.path)
        let repository = PromptRepository(dbQueue: database.dbQueue)
        let editing = PromptEditingService(dbQueue: database.dbQueue)
        var prompt = try editing.create(Prompt(name: "Versioned CLI", content: "# One"))
        prompt.content = "# Two"
        prompt.updatedAt = Date()
        _ = try editing.save(prompt)

        let history = try PromptsCommand.HistorySubcommand.parse([
            prompt.id.uuidString, "--json", "--database", databaseURL.path,
        ])
        let historyOutput = try captureStandardOutput { try history.run() }
        let versions = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(historyOutput.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(versions.compactMap { $0["versionNumber"] as? Int }, [2, 1])

        let diff = try PromptsCommand.DiffSubcommand.parse([
            prompt.id.uuidString, "--from", "1", "--to", "2", "--json",
            "--database", databaseURL.path,
        ])
        let diffOutput = try captureStandardOutput { try diff.run() }
        let diffRecord = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(diffOutput.utf8)) as? [String: Any]
        )
        XCTAssertEqual(diffRecord["hasChanges"] as? Bool, true)

        let restore = try PromptsCommand.RestoreSubcommand.parse([
            prompt.id.uuidString, "--version", "1", "--json", "--database", databaseURL.path,
        ])
        _ = try captureStandardOutput { try restore.run() }
        let restored = try XCTUnwrap(repository.fetch(id: prompt.id))
        XCTAssertEqual(restored.content, "# One")
        XCTAssertEqual(
            try PromptVersionRepository(dbQueue: database.dbQueue).fetchActive(promptId: prompt.id)?.versionNumber,
            3
        )
    }

    func testSetAcceptsModelAndLabelPolicies() throws {
        let model = try PromptsCommand.SetSubcommand.parse(["Prompt", "--model", "qwen-local"])
        XCTAssertEqual(model.model, "qwen-local")
        XCTAssertNoThrow(try PromptsCommand.SetSubcommand.parse(["Prompt", "--active-model"]))
        let policy = try PromptsCommand.SetSubcommand.parse([
            "Prompt", "--label", "Customer", "--available",
        ])
        XCTAssertEqual(policy.label, "Customer")
        XCTAssertTrue(policy.available)
        XCTAssertNoThrow(try PromptsCommand.SetSubcommand.parse([
            "Polish", "--temperature", "0.3", "--thinking-mode", "enabled",
            "--reasoning-effort", "low",
        ]))
    }

    func testSetRejectsInvalidPolicyCombinations() {
        XCTAssertThrowsError(try PromptsCommand.SetSubcommand.parse(["Prompt", "--available"]))
        XCTAssertThrowsError(try PromptsCommand.SetSubcommand.parse([
            "Prompt", "--meeting-type", "Customer", "--all-meeting-types", "--available",
        ]))
        XCTAssertThrowsError(try PromptsCommand.SetSubcommand.parse(["Prompt", "--model", " "]))
    }

    func testStoredPromptRunResultUsesEffectiveSettingsReceipt() {
        let transcript = Transcription(
            fileName: "Meeting",
            rawTranscript: "Transcript",
            status: .completed,
            userNotes: "Keep this detail"
        )
        let requested = PromptInferenceSettings(
            temperature: 0.4,
            topK: 40,
            thinkingMode: .enabled
        )
        let effective = PromptInferenceSettings(temperature: 0.4)
        let prompt = Prompt(
            name: "Configured",
            content: "Summarize.",
            inferenceSettings: requested
        )

        let result = makeStoredPromptRunResult(
            transcript: transcript,
            prompt: prompt,
            extraInstructions: "Brief.",
            output: "Result",
            userNotesSnapshot: nil,
            effectiveSettings: effective
        )

        XCTAssertEqual(result.transcriptionId, transcript.id)
        XCTAssertEqual(result.promptId, prompt.id)
        XCTAssertEqual(result.promptVersionId, prompt.activeVersionId)
        XCTAssertEqual(result.promptName, prompt.name)
        XCTAssertNil(result.userNotesSnapshot)
        XCTAssertFalse(result.includeMeetingNotesSnapshot)
        XCTAssertEqual(result.inferenceSettingsSnapshot, effective)
        XCTAssertNotEqual(result.inferenceSettingsSnapshot, requested)
    }

    func testStoredPromptRunResultUsesExactEffectiveNotesReceiptAndPreference() {
        let transcript = Transcription(
            fileName: "Meeting",
            rawTranscript: "Transcript",
            status: .completed,
            userNotes: "Canonical notes are not copied implicitly"
        )
        let prompt = Prompt(
            name: "Configured",
            content: "Summarize.",
            includeMeetingNotes: true
        )
        let effectiveNotes = "Exact capped notes receipt"

        let result = makeStoredPromptRunResult(
            transcript: transcript,
            prompt: prompt,
            extraInstructions: nil,
            output: "Result",
            userNotesSnapshot: effectiveNotes,
            effectiveSettings: nil
        )

        XCTAssertEqual(result.userNotesSnapshot, effectiveNotes)
        XCTAssertTrue(result.includeMeetingNotesSnapshot)
    }

    func testTransformSupportsVersionedSettingsThroughPromptCommands() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transform-prompt-cli-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let database = try DatabaseManager(path: databaseURL.path)
        let repository = PromptRepository(dbQueue: database.dbQueue)
        let transform = try XCTUnwrap(
            try repository.fetchVisible(category: .transform).first(where: { $0.name == "Polish" })
        )

        let set = try PromptsCommand.SetSubcommand.parse([
            transform.id.uuidString,
            "--temperature", "0.3",
            "--thinking-mode", "enabled",
            "--reasoning-effort", "low",
            "--model", "house-model",
            "--json",
            "--database", databaseURL.path,
        ])
        let output = try captureStandardOutput { try set.run() }
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(record["activeVersionNumber"] as? Int, 2)
        XCTAssertEqual(record["modelOverride"] as? String, "house-model")
        let settings = try XCTUnwrap(record["inferenceSettings"] as? [String: Any])
        XCTAssertEqual(settings["temperature"] as? Double, 0.3)
        XCTAssertEqual(settings["thinkingMode"] as? String, "enabled")

        let history = try PromptsCommand.HistorySubcommand.parse([
            transform.id.uuidString, "--json", "--database", databaseURL.path,
        ])
        let historyOutput = try captureStandardOutput { try history.run() }
        let versions = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(historyOutput.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(versions.compactMap { $0["versionNumber"] as? Int }, [2, 1])
    }

    func testObsoleteMeetingPoliciesFailWithMigrationGuidance() {
        for target in [["--all-meeting-types"], ["--meeting-type", "Customer"]] {
            XCTAssertThrowsError(try PromptsCommand.SetSubcommand.parse(
                ["Prompt"] + target + ["--unavailable"]
            )) { error in
                XCTAssertTrue(String(describing: error).contains("--label"))
                XCTAssertTrue(String(describing: error).contains("--source meeting"))
            }
        }
        XCTAssertThrowsError(try PromptsCommand.SetSubcommand.parse([
            "Prompt", "--label", "Customer", "--available", "--auto-run",
        ]))
    }

    func testFirstLabelDenialPreservesOtherTranscriptions() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-first-policy-cli-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let database = try DatabaseManager(path: databaseURL.path)
        let prompt = try PromptEditingService(dbQueue: database.dbQueue).create(
            Prompt(name: "First exception", content: "Summarize.")
        )
        let label = MeetingLabel(name: "Excluded")
        try MeetingLabelRepository(dbQueue: database.dbQueue).save(label)
        let setter = try PromptsCommand.SetSubcommand.parse([
            prompt.id.uuidString, "--label", label.id.uuidString, "--unavailable",
            "--database", databaseURL.path,
        ])
        try setter.run()
        for excluded in [false, true] {
            let transcript = Transcription(fileName: "Exception", rawTranscript: "Source text", status: .completed)
            try TranscriptionRepository(dbQueue: database.dbQueue).save(transcript)
            if excluded {
                try TranscriptionMeetingLabelRepository(dbQueue: database.dbQueue).add(labelId: label.id, to: transcript.id)
            }
            let runner = try PromptsCommand.RunSubcommand.parse([
                prompt.id.uuidString, "--transcription", transcript.id.uuidString,
                "--provider", "cli", "--command", "/usr/bin/printf other-labels-preserved",
                "--database", databaseURL.path,
            ])
            if excluded {
                do {
                    try await runner.run()
                    XCTFail("The explicitly excluded label must not run")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("is unavailable"), "\(error)")
                }
            } else {
                try await runner.run()
                let results = try PromptResultRepository(dbQueue: database.dbQueue).fetchAll(transcriptionId: transcript.id)
                XCTAssertEqual(results.first?.content, "other-labels-preserved")
            }
        }
    }

    func testLabelPolicyMutationsControlExecutionAndPreserveExplicitExceptions() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-policy-cli-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let database = try DatabaseManager(path: databaseURL.path)
        let prompt = try PromptEditingService(dbQueue: database.dbQueue).create(
            Prompt(name: "CLI targeted", content: "Summarize.", isAutoRun: true, appliesToSources: [.meeting])
        )
        let target = MeetingLabel(name: "Allowed label")
        try MeetingLabelRepository(dbQueue: database.dbQueue).save(target)
        for flags in [["--all-labels", "--unavailable"], ["--label", target.id.uuidString, "--available"]] {
            let command = try PromptsCommand.SetSubcommand.parse(
                [prompt.id.uuidString] + flags + ["--json", "--database", databaseURL.path]
            )
            let output = try captureStandardOutput { try command.run() }
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            XCTAssertEqual(record["scopeKind"] as? String, flags[0] == "--all-labels" ? "all" : "label")
        }
        let savedPrompt = try XCTUnwrap(PromptRepository(dbQueue: database.dbQueue).fetch(id: prompt.id))
        XCTAssertTrue(savedPrompt.autoRuns(for: .meeting))
        XCTAssertFalse(savedPrompt.autoRuns(for: .file))
        for source in Transcription.SourceType.allCases {
            for hasTarget in [false, true] {
                let transcript = Transcription(
                    fileName: "CLI policy", rawTranscript: "Source text", status: .completed, sourceType: source
                )
                try TranscriptionRepository(dbQueue: database.dbQueue).save(transcript)
                if hasTarget {
                    try TranscriptionMeetingLabelRepository(dbQueue: database.dbQueue)
                        .add(labelId: target.id, to: transcript.id)
                }
                let command = try PromptsCommand.RunSubcommand.parse([
                    prompt.id.uuidString, "--transcription", transcript.id.uuidString,
                    "--provider", "cli", "--command", "/usr/bin/printf policy-accepted",
                    "--database", databaseURL.path,
                ])
                if hasTarget {
                    try await command.run()
                    let results = try PromptResultRepository(dbQueue: database.dbQueue).fetchAll(transcriptionId: transcript.id)
                    XCTAssertEqual(results.first?.content, "policy-accepted")
                } else {
                    do {
                        try await command.run()
                        XCTFail("Expected unavailable fallback for \(source)")
                    } catch {
                        XCTAssertTrue(error.localizedDescription.contains("is unavailable"), "\(error)")
                    }
                }
            }
        }
        // Updating the fallback must not erase an explicit denial.
        for flags in [["--label", target.id.uuidString, "--unavailable"], ["--all-labels", "--available"]] {
            let command = try PromptsCommand.SetSubcommand.parse(
                [prompt.id.uuidString] + flags + ["--database", databaseURL.path]
            )
            try command.run()
        }
        let policies = try PromptLabelPolicyRepository(dbQueue: database.dbQueue).fetchPolicies(promptId: prompt.id)
        XCTAssertFalse(PromptLabelApplicabilityResolver.resolve(
            prompt: savedPrompt, sourceType: .meeting, transcriptionLabelIDs: [target.id], policies: policies
        ).isAvailable)
        XCTAssertTrue(PromptLabelApplicabilityResolver.resolve(
            prompt: savedPrompt, sourceType: .file, transcriptionLabelIDs: [], policies: policies
        ).isAvailable)
    }

    func testRunRejectsNonmatchingLabelForEverySourceBeforeProviderExecution() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-cli-label-policy-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let database = try DatabaseManager(path: databaseURL.path)
        let prompt = try PromptEditingService(dbQueue: database.dbQueue).create(
            Prompt(name: "Restricted label prompt", content: "Summarize.")
        )
        let target = MeetingLabel(name: "Required")
        let unrelated = MeetingLabel(name: "Unrelated")
        let labels = MeetingLabelRepository(dbQueue: database.dbQueue)
        try labels.save(target)
        try labels.save(unrelated)
        try PromptLabelPolicyRepository(dbQueue: database.dbQueue).replaceTargetLabels(
            promptId: prompt.id, labelIds: [target.id]
        )

        for source in Transcription.SourceType.allCases {
            for hasUnrelatedLabel in [false, true] {
                let transcription = Transcription(
                    fileName: "Restricted \(source.rawValue)",
                    rawTranscript: "A transcript that must not reach the provider.",
                    status: .completed,
                    sourceType: source
                )
                try TranscriptionRepository(dbQueue: database.dbQueue).save(transcription)
                if hasUnrelatedLabel {
                    try TranscriptionMeetingLabelRepository(dbQueue: database.dbQueue)
                        .add(labelId: unrelated.id, to: transcription.id)
                }
                let command = try PromptsCommand.RunSubcommand.parse([
                    prompt.id.uuidString, "--transcription", transcription.id.uuidString,
                    "--provider", "cli", "--command", "/usr/bin/printf unexpected-provider-execution",
                    "--no-store", "--database", databaseURL.path,
                ])
                do {
                    try await command.run()
                    XCTFail("Expected label policy rejection for \(source.rawValue)")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("is unavailable"), "\(error)")
                    XCTAssertTrue(error.localizedDescription.contains("allLabelsPolicy"), "\(error)")
                }
            }
        }
    }

    func testRunAcceptsMatchingLabelForEverySourceDespiteLegacyMeetingDenial() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-cli-matching-label-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let database = try DatabaseManager(path: databaseURL.path)
        let prompt = try PromptEditingService(dbQueue: database.dbQueue).create(
            Prompt(name: "Label prompt", content: "Summarize.", isAutoRun: false)
        )
        let firstTarget = MeetingLabel(name: "First target")
        let secondTarget = MeetingLabel(name: "Second target")
        let labels = MeetingLabelRepository(dbQueue: database.dbQueue)
        try labels.save(firstTarget)
        try labels.save(secondTarget)
        try PromptLabelPolicyRepository(dbQueue: database.dbQueue).replaceTargetLabels(
            promptId: prompt.id, labelIds: [firstTarget.id, secondTarget.id]
        )
        _ = try PromptMeetingPolicyRepository(dbQueue: database.dbQueue).setAllMeetingsPolicy(
            promptId: prompt.id, isAvailable: false, isAutoRun: false, sortOrder: nil
        )

        for source in Transcription.SourceType.allCases {
            let transcription = Transcription(
                fileName: "Matching \(source.rawValue)", rawTranscript: "Transcript.",
                status: .completed, sourceType: source
            )
            try TranscriptionRepository(dbQueue: database.dbQueue).save(transcription)
            try TranscriptionMeetingLabelRepository(dbQueue: database.dbQueue)
                .add(labelId: secondTarget.id, to: transcription.id)
            let command = try PromptsCommand.RunSubcommand.parse([
                prompt.id.uuidString, "--transcription", transcription.id.uuidString,
                "--provider", "cli", "--command", "/usr/bin/printf label-policy-accepted",
                "--database", databaseURL.path,
            ])
            try await command.run()
            let results = try PromptResultRepository(dbQueue: database.dbQueue)
                .fetchAll(transcriptionId: transcription.id)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.content, "label-policy-accepted")
        }
    }

    func testRunRejectsHiddenPromptForNonMeetingBeforeProviderExecution() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-cli-hidden-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let database = try DatabaseManager(path: databaseURL.path)
        var prompt = try PromptEditingService(dbQueue: database.dbQueue).create(
            Prompt(name: "Hidden result", content: "Summarize.")
        )
        prompt.isVisible = false
        prompt = try PromptEditingService(dbQueue: database.dbQueue).save(prompt)
        let transcription = Transcription(
            fileName: "Saved file", rawTranscript: "Do not send.", status: .completed, sourceType: .file
        )
        try TranscriptionRepository(dbQueue: database.dbQueue).save(transcription)
        let command = try PromptsCommand.RunSubcommand.parse([
            prompt.id.uuidString, "--transcription", transcription.id.uuidString,
            "--provider", "anthropic", "--api-key", "unused", "--no-store",
            "--database", databaseURL.path,
        ])
        do {
            try await command.run()
            XCTFail("Expected hidden prompt rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("is unavailable"))
            XCTAssertTrue(error.localizedDescription.contains("hidden"))
        }
    }

    // MARK: - findPrompt

    func testFindPromptByExactUUID() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let p = Prompt(name: "Custom A", content: "Hello")
        try repo.save(p)

        let found = try findPrompt(idOrName: p.id.uuidString, repo: repo)
        XCTAssertEqual(found.id, p.id)
    }

    func testFindPromptByPrefix() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let p = Prompt(name: "Custom B", content: "Hello")
        try repo.save(p)

        let prefix = String(p.id.uuidString.prefix(8))
        let found = try findPrompt(idOrName: prefix, repo: repo)
        XCTAssertEqual(found.id, p.id)
    }

    func testFindPromptRejectsShortUUIDPrefixUnlessItIsName() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let uuid = UUID(uuidString: "DDBBCCAA-1111-1111-1111-111111111111")!
        let p = Prompt(id: uuid, name: "Custom", content: "Hello")
        try repo.save(p)

        XCTAssertThrowsError(try findPrompt(idOrName: "ddb", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .shortUUIDPrefix(let minimumLength) = lookupError {
                XCTAssertEqual(minimumLength, 4)
            } else {
                XCTFail("Expected .shortUUIDPrefix, got \(lookupError)")
            }
        }

        let nameOnly = Prompt(name: "dd", content: "Name")
        try repo.save(nameOnly)
        let foundByName = try findPrompt(idOrName: "dd", repo: repo)
        XCTAssertEqual(foundByName.id, nameOnly.id)
    }

    func testFindPromptByNameCaseInsensitive() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let p = Prompt(name: "My Special Prompt", content: "Hello")
        try repo.save(p)

        let found = try findPrompt(idOrName: "my special prompt", repo: repo)
        XCTAssertEqual(found.id, p.id)
    }

    func testFindPromptIgnoresTransformRows() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let polish = try XCTUnwrap(
            (try repo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Polish" })
        )

        XCTAssertThrowsError(try findPrompt(idOrName: "Polish", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .notFound = lookupError {
            } else {
                XCTFail("Expected .notFound, got \(lookupError)")
            }
        }
        XCTAssertThrowsError(try findPrompt(idOrName: polish.id.uuidString, repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .notFound = lookupError {
            } else {
                XCTFail("Expected .notFound, got \(lookupError)")
            }
        }
    }

    func testFindPromptThrowsNotFoundForBogusInput() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findPrompt(idOrName: "nonexistent-prompt-name", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .notFound = lookupError {
            } else {
                XCTFail("Expected .notFound, got \(lookupError)")
            }
        }
    }

    func testFindPromptThrowsEmptyIDForWhitespace() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findPrompt(idOrName: "   ", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError")
            }
            if case .emptyID = lookupError {
            } else {
                XCTFail("Expected .emptyID, got \(lookupError)")
            }
        }
    }

    func testFindPromptThrowsAmbiguousForSharedPrefix() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)

        let uuid1 = UUID(uuidString: "CCDDEEFF-1111-1111-1111-111111111111")!
        let uuid2 = UUID(uuidString: "CCDDEEFF-2222-2222-2222-222222222222")!
        try repo.save(Prompt(id: uuid1, name: "X", content: "x"))
        try repo.save(Prompt(id: uuid2, name: "Y", content: "y"))

        XCTAssertThrowsError(try findPrompt(idOrName: "CCDDEEFF", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError")
            }
            if case .ambiguous = lookupError {
            } else {
                XCTFail("Expected .ambiguous, got \(lookupError)")
            }
        }
    }

    func testFindPromptPrefersIDPrefixOverName() throws {
        // If a name happens to look like a UUID prefix that also matches a real
        // prompt's UUID, the ID match wins. This mirrors the precedence in
        // findTranscription/findDictation.
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)

        let realID = UUID(uuidString: "DEADBEEF-1111-1111-1111-111111111111")!
        try repo.save(Prompt(id: realID, name: "Real", content: "real"))
        try repo.save(Prompt(name: "deadbeef", content: "name-only"))

        let found = try findPrompt(idOrName: "deadbeef", repo: repo)
        XCTAssertEqual(found.id, realID, "ID prefix match should beat case-insensitive name match")
    }

    // MARK: - cliJSONEncoder smoke

    func testListJSONExcludesTransformPrompts() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        _ = try DatabaseManager(path: dbPath)

        let command = try PromptsCommand.ListSubcommand.parse([
            "--json",
            "--database", dbPath,
        ])
        let output = try captureStandardOutput { try command.run() }
        let prompts = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        )

        XCTAssertEqual(prompts.count, 6)
        XCTAssertTrue(prompts.allSatisfy { $0["category"] as? String == Prompt.Category.result.rawValue })
        XCTAssertFalse(prompts.contains(where: { $0["name"] as? String == "Polish" }))
    }

    // MARK: - Set validation
    // .parse() runs validate() automatically, so a failed parse with our error
    // text proves validate() rejected it.

    func testSetRejectsContradictoryHiddenAndAutoRun() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse(["anything", "--hidden", "--auto-run"])
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("auto-run requires visible"),
                          "Expected message about auto-run requiring visible, got: \(error)")
        }
    }

    func testSetRejectsMutuallyExclusiveVisibleHidden() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse(["anything", "--visible", "--hidden"])
        )
    }

    func testSetRequiresAtLeastOneFlag() {
        XCTAssertThrowsError(try PromptsCommand.SetSubcommand.parse(["anything"]))
    }

    func testSetAcceptsHiddenWithNoAutoRun() {
        XCTAssertNoThrow(
            try PromptsCommand.SetSubcommand.parse(["anything", "--hidden", "--no-auto-run"])
        )
    }

    func testSetAcceptsSourceScopedAutoRun() throws {
        let command = try PromptsCommand.SetSubcommand.parse([
            "anything",
            "--auto-run",
            "--source", "meeting",
        ])

        XCTAssertEqual(command.source, .meeting)
    }

    func testSetRejectsSourceWithoutAutoRunFlag() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse(["anything", "--source", "meeting"])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("--source requires"))
        }
    }

    func testSetRejectsSourceWithVisibilityFlags() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse(["anything", "--visible", "--source", "meeting"])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("--source can only"))
        }
    }

    func testSetRejectsContradictoryMeetingNotesFlags() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse([
                "anything", "--include-meeting-notes", "--no-include-meeting-notes",
            ])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("mutually exclusive"))
        }
    }

    func testSetMeetingNotesFlagPersistsAndAppearsInJSON() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-notes-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let db = try DatabaseManager(path: dbPath)
        let prompt = try XCTUnwrap(try PromptRepository(dbQueue: db.dbQueue).fetchAll().first)

        let command = try PromptsCommand.SetSubcommand.parse([
            prompt.id.uuidString,
            "--include-meeting-notes",
            "--json",
            "--database", dbPath,
        ])
        let output = try captureStandardOutput { try command.run() }
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["includeMeetingNotes"] as? Bool, true)
    }

    func testMeetingNotesLookupPrefersResultsWithoutLosingExactUUIDIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-lookup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("test.db").path
        let manager = try DatabaseManager(path: databasePath)
        let repository = PromptRepository(dbQueue: manager.dbQueue)
        let result = Prompt(
            id: UUID(uuidString: "CCDDEEFF-1111-1111-1111-111111111111")!,
            name: "Result prefix target", content: "Result"
        )
        let transform = Prompt(
            id: UUID(uuidString: "CCDDEEFF-2222-2222-2222-222222222222")!,
            name: "Transform prefix target", content: "Transform", category: .transform
        )
        try repository.save(result)
        try repository.save(transform)
        for flag in ["--include-meeting-notes", "--no-include-meeting-notes"] {
            let command = try PromptsCommand.SetSubcommand.parse([
                "CCDDEEFF", flag, "--database", databasePath,
            ])
            try command.run()
            XCTAssertEqual(try repository.fetch(id: result.id)?.includeMeetingNotes, flag == "--include-meeting-notes")
            XCTAssertEqual(try repository.fetch(id: transform.id)?.includeMeetingNotes, false)
        }

        // A result name that resembles only a transform's prefix still
        // resolves as a name within the result-specific notes operation.
        let namedResult = Prompt(name: "CCDDEEFF-2222", content: "Named result")
        try repository.save(namedResult)
        let namedCommand = try PromptsCommand.SetSubcommand.parse([
            namedResult.name, "--include-meeting-notes", "--database", databasePath,
        ])
        try namedCommand.run()
        XCTAssertEqual(try repository.fetch(id: namedResult.id)?.includeMeetingNotes, true)

        // Exact UUID precedence must still reject a transform, rather than
        // modifying a result with a display name equal to that UUID.
        let uuidNamedResult = Prompt(name: transform.id.uuidString, content: "UUID display name")
        try repository.save(uuidNamedResult)
        let exactCommand = try PromptsCommand.SetSubcommand.parse([
            transform.id.uuidString, "--include-meeting-notes", "--database", databasePath,
        ])
        XCTAssertThrowsError(try exactCommand.run()) { error in
            XCTAssertTrue(String(describing: error).contains("only available for result prompts"))
        }
        XCTAssertEqual(try repository.fetch(id: uuidNamedResult.id)?.includeMeetingNotes, false)

        // Ambiguity among results must not fall through to wider lookup.
        try repository.save(Prompt(
            id: UUID(uuidString: "CCDDEEFF-3333-3333-3333-333333333333")!,
            name: "Second result", content: "Result"
        ))
        let ambiguous = try PromptsCommand.SetSubcommand.parse([
            "CCDDEEFF", "--include-meeting-notes", "--database", databasePath,
        ])
        XCTAssertThrowsError(try ambiguous.run()) { error in
            guard case CLILookupError.ambiguous = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testSetMeetingNotesFlagRejectsTransformPrompt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-notes-transform-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let db = try DatabaseManager(path: dbPath)
        let transform = try XCTUnwrap(
            try PromptRepository(dbQueue: db.dbQueue).fetchVisible(category: .transform).first
        )
        let command = try PromptsCommand.SetSubcommand.parse([
            transform.id.uuidString,
            "--include-meeting-notes",
            "--database", dbPath,
        ])

        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertEqual(
                CLI.normalizedExitCode(for: error),
                cliValidationMisuseExitCode,
                "Unexpected error: \(type(of: error)): \(error)"
            )
        }
        XCTAssertFalse(try XCTUnwrap(PromptRepository(dbQueue: db.dbQueue).fetch(id: transform.id)).includeMeetingNotes)
    }

    // MARK: - Set flag semantics (applyFlags)

    func testSetAutoRunClearsPerSourceScope() {
        // A prompt narrowed to meetings-only in the GUI must not stay scoped when
        // the CLI enables global auto-run — otherwise it claims global-on while
        // silently firing on meetings only.
        let inferenceSettings = PromptInferenceSettings(temperature: 0.3, maxTokens: 450)
        var prompt = Prompt(
            name: "Summary",
            content: "x",
            category: .result,
            inferenceSettings: inferenceSettings
        )
        prompt.isAutoRun = true
        prompt.appliesToSources = [.meeting]

        PromptsCommand.SetSubcommand.applyFlags(
            to: &prompt, visible: false, hidden: false, autoRun: true, noAutoRun: false
        )

        XCTAssertTrue(prompt.isAutoRun)
        XCTAssertTrue(prompt.isVisible)
        XCTAssertNil(prompt.appliesToSources, "global --auto-run resets scope to all sources")
        XCTAssertEqual(prompt.inferenceSettings, inferenceSettings)
    }

    func testSetNoAutoRunClearsPerSourceScope() {
        var prompt = Prompt(name: "Summary", content: "x", category: .result)
        prompt.isAutoRun = true
        prompt.appliesToSources = [.meeting]

        PromptsCommand.SetSubcommand.applyFlags(
            to: &prompt, visible: false, hidden: false, autoRun: false, noAutoRun: true
        )

        XCTAssertFalse(prompt.isAutoRun)
        XCTAssertNil(prompt.appliesToSources, "disabling auto-run returns to a clean nil scope")
    }

    func testSetHiddenClearsAutoRunAndScope() {
        var prompt = Prompt(name: "Summary", content: "x", category: .result)
        prompt.isAutoRun = true
        prompt.appliesToSources = [.meeting]

        PromptsCommand.SetSubcommand.applyFlags(
            to: &prompt, visible: false, hidden: true, autoRun: false, noAutoRun: false
        )

        XCTAssertFalse(prompt.isVisible)
        XCTAssertFalse(prompt.isAutoRun)
        XCTAssertNil(prompt.appliesToSources)
    }

    func testSetSourceScopedAutoRunUsesRepositoryScoping() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-source-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let db = try DatabaseManager(path: dbPath)
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let inferenceSettings = PromptInferenceSettings(topP: 0.8, maxTokens: 700)
        let prompt = Prompt(
            name: "Meeting Follow-up",
            content: "x",
            category: .result,
            inferenceSettings: inferenceSettings
        )
        try repo.save(prompt)

        let command = try PromptsCommand.SetSubcommand.parse([
            prompt.id.uuidString,
            "--auto-run",
            "--source", "meeting",
            "--database", dbPath,
        ])
        _ = try captureStandardOutput {
            try command.run()
        }

        let updated = try XCTUnwrap(repo.fetch(id: prompt.id))
        XCTAssertTrue(updated.isAutoRun)
        XCTAssertTrue(updated.isVisible)
        XCTAssertEqual(updated.appliesToSources, [.meeting])
        XCTAssertEqual(updated.inferenceSettings, inferenceSettings)
        XCTAssertTrue(updated.autoRuns(for: .meeting))
        XCTAssertFalse(updated.autoRuns(for: .file))
    }

    func testSetSourceScopedAutoRunJSONEmitsUpdatedPrompt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-source-cli-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let db = try DatabaseManager(path: dbPath)
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let prompt = Prompt(name: "Meeting Follow-up", content: "x", category: .result)
        try repo.save(prompt)

        let command = try PromptsCommand.SetSubcommand.parse([
            prompt.id.uuidString,
            "--auto-run",
            "--source", "meeting",
            "--database", dbPath,
            "--json",
        ])
        let output = try captureStandardOutput {
            try command.run()
        }

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["id"] as? String, prompt.id.uuidString.uppercased())
        XCTAssertEqual(decoded["name"] as? String, "Meeting Follow-up")
        XCTAssertEqual(decoded["isAutoRun"] as? Bool, true)
        XCTAssertEqual(decoded["isVisible"] as? Bool, true)
        XCTAssertEqual(decoded["appliesToSources"] as? [String], ["meeting"])
    }

    func testSetJSONLookupFailureEmitsEnvelope() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-source-cli-json-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        _ = try DatabaseManager(path: dbPath)

        let command = try PromptsCommand.SetSubcommand.parse([
            "missing",
            "--auto-run",
            "--database", dbPath,
            "--json",
        ])
        var thrownError: Error?
        let output = try captureStandardOutput {
            do {
                try command.run()
            } catch {
                thrownError = error
            }
        }

        let error = try XCTUnwrap(thrownError)
        XCTAssertTrue(error is CLIJSONEnvelopeExit)
        XCTAssertEqual(CLI.normalizedExitCode(for: error), .failure)

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["ok"] as? Bool, false)
        XCTAssertEqual(decoded["errorType"] as? String, "lookup")
        XCTAssertTrue((decoded["error"] as? String)?.contains("No prompt matching") == true)
    }

    func testRestoreDefaultsKeepsTransformVisibilityCompatibility() throws {
        XCTAssertEqual(
            PromptsCommand.RestoreDefaultsSubcommand.configuration.abstract,
            "Re-show built-in result prompts and hidden built-in Transforms."
        )

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-restore-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let manager = try DatabaseManager(path: dbPath)
        let repo = PromptRepository(dbQueue: manager.dbQueue)
        let transform = try XCTUnwrap(
            (try repo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Polish" })
        )
        try repo.toggleVisibility(id: transform.id)
        XCTAssertFalse(try XCTUnwrap(try repo.fetch(id: transform.id)).isVisible)

        let command = try PromptsCommand.RestoreDefaultsSubcommand.parse([
            "--database", dbPath,
        ])
        let output = try captureStandardOutput {
            try command.run()
        }

        XCTAssertTrue(output.contains("Built-in result prompts and hidden built-in Transforms re-shown."))
        XCTAssertTrue(try XCTUnwrap(try repo.fetch(id: transform.id)).isVisible)
    }

    func testSetSourceScopedNoAutoRunNarrowsGlobalAutoRun() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-source-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let db = try DatabaseManager(path: dbPath)
        let repo = PromptRepository(dbQueue: db.dbQueue)
        var prompt = Prompt(name: "All Sources", content: "x", category: .result, isAutoRun: true)
        prompt.appliesToSources = nil
        try repo.save(prompt)

        let command = try PromptsCommand.SetSubcommand.parse([
            prompt.id.uuidString,
            "--no-auto-run",
            "--source", "meeting",
            "--database", dbPath,
        ])
        _ = try captureStandardOutput {
            try command.run()
        }

        let updated = try XCTUnwrap(repo.fetch(id: prompt.id))
        XCTAssertTrue(updated.isAutoRun)
        XCTAssertEqual(updated.appliesToSources, [.file, .youtube, .podcast])
        XCTAssertFalse(updated.autoRuns(for: .meeting))
        XCTAssertTrue(updated.autoRuns(for: .file))
    }

    // MARK: - Add validation

    func testAddRejectsContentAndFromFileTogether() {
        XCTAssertThrowsError(
            try PromptsCommand.AddSubcommand.parse([
                "--name", "X", "--content", "body", "--from-file", "/tmp/file.txt",
            ])
        )
    }

    func testAddAllowsNeitherSet() {
        // Neither set means "read body from stdin" — parsing must succeed; the
        // empty-body guard runs in run(), not validate().
        XCTAssertNoThrow(try PromptsCommand.AddSubcommand.parse(["--name", "X"]))
    }

    func testAddRejectsEmptyName() {
        XCTAssertThrowsError(
            try PromptsCommand.AddSubcommand.parse(["--name", "   ", "--content", "body"])
        )
    }

    // MARK: - JSON encoder

    func testCLIJSONEncoderEmitsParseableJSON() throws {
        // DatabaseManager() seeds 6 built-in prompts during migration, so we
        // can't assume insertion order — search by name instead of position.
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        try repo.save(Prompt(name: "JSON Test", content: "Body"))

        let prompts = try repo.fetchAll()
        let data = try cliJSONEncoder.encode(prompts)

        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertNotNil(parsed)
        let names = parsed?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("JSON Test"), "Expected 'JSON Test' in encoded names; got: \(names)")
    }
}
