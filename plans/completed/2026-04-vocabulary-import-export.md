# Vocabulary Import / Export

> Status: **HISTORICAL**
> Origin: Issue #67 (Daniel, 2026-04-06) — "make it possible to import and export your vocabulary"
> Branch: `feat/vocabulary-import-export`

## Goal

Let users back up and restore their custom words + text snippets through a single, human-readable JSON file. Visible from the Vocabulary panel — not buried.

## Why

Daniel's specific anxiety: **losing settings on update / clear-derived-data**. He's curated a long list of Australian-English corrections and wants a backup file. iCloud sync was explicitly *not* requested.

This is also a portability feature — moving vocab from one Mac to another, sharing with teammates, version-controlling your own vocabulary.

## Scope

In:
- Combined export of custom words + text snippets in one JSON file.
- Import from JSON with a preview sheet showing counts + conflicts.
- Two conflict policies: skip duplicates (default) or replace.
- "Backup & Restore" card on the Vocabulary panel (main page).
- CLI commands: `flow vocabulary export`, `flow vocabulary import`, and
  `flow vocabulary schema`.

Out:
- Per-table exports (one file is what Daniel asked for).
- iCloud / cloud sync.
- New telemetry events (avoid cross-repo allowlist change in this PR).
- Encrypted exports. Text snippets may contain private data such as addresses,
  signatures, or phone numbers; encryption is out of scope for v1 and should be
  handled as a follow-up or documented privacy caveat.

## File format

```json
{
  "schema": "macparakeet.vocabulary",
  "version": 1,
  "exportedAt": "2026-04-28T12:34:56Z",
  "appVersion": "0.6.0",
  "customWords": [
    { "word": "Daniel", "replacement": null, "isEnabled": true, "createdAt": "..." }
  ],
  "textSnippets": [
    { "trigger": "addr", "expansion": "...", "isEnabled": true, "action": null, "createdAt": "..." }
  ]
}
```

Decisions:
- **Drop UUIDs.** PKs are local; UUID conflicts on import would be spurious. Generate fresh on import.
- **Drop `source` and `useCount`.** Export only `.manual` words; `.learned` regenerates on each Mac. `useCount` is local stats noise.
- **Keep `createdAt`** so chronological ordering survives a round-trip; `updatedAt` reset on import.
- **Versioned schema.** Future-proofing without committing to anything yet.

## Conflict detection

- Custom words: case-insensitive match on `word` (mirrors `addWord` dedupe rule).
- Snippets: case-insensitive match on `trigger` (mirrors `addSnippet` dedupe rule).
- Skip policy: existing record untouched, imported record discarded.
- Replace policy: existing record deleted by id, imported record inserted with fresh UUID.

## Files

New:
- `Sources/MacParakeetCore/Models/VocabularyBundle.swift` — Codable DTO.
- `Sources/MacParakeetCore/Services/VocabularyImportExportService.swift` — pure data shuffling.
- `Sources/MacParakeetViewModels/VocabularyBackupViewModel.swift` — UI state.
- `Sources/MacParakeet/Views/Vocabulary/VocabularyBackupSection.swift` — card + buttons.
- `Sources/MacParakeet/Views/Vocabulary/VocabularyImportPreviewSheet.swift` — modal sheet.
- `Tests/MacParakeetTests/Services/VocabularyImportExportServiceTests.swift`.

Modified:
- `Sources/MacParakeet/Views/Vocabulary/VocabularyView.swift` — add backup card.
- `Sources/MacParakeet/AppDelegate.swift` + `AppEnvironmentConfigurer.swift` — wire service + view model.
- `spec/02-features.md` — note vocabulary backup under Vocabulary section.

## Test plan

Service round-trip + edge cases (10+ tests). UI verified manually:
1. Export → file written, contents valid JSON, opens in text editor.
2. Wipe DB, import → all entries restored, fresh UUIDs.
3. Re-import same file → all conflicts, skip leaves untouched, replace updates.
4. Import malformed JSON → friendly error, no DB changes.
5. Import bundle from "future version" → friendly upgrade message.
6. Empty DB export → valid file with empty arrays.

## Out-of-scope risks acknowledged

- `.learned` words are NOT in exports. If a user has trained corrections via accept-prompt, they'll need to re-train on the new machine. Acceptable for v1; documented in plan.
- No diff preview ("here are the actual entries that will conflict"). Counts + first 5 examples only. Diff UI can come later if asked.
