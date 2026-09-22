# Reusable GUI fixtures for 0.8.0 QA

The [seed script](scripts/seed_gui_fixtures.py) adds synthetic saved content to an
explicitly selected QA database. It does not generate speech or call an LLM.
Quit the app that owns the database normally before inserting fixtures, then
relaunch the same isolated app. The script does not detect running app processes.

From the QA worktree:

```sh
python3 docs/qa/2026-09-07-0.8.0/scripts/seed_gui_fixtures.py \
  --database '/tmp/macparakeet-080-qa/isolated-home/Library/Application Support/MacParakeet/macparakeet.db' \
  --dry-run

# Run this insertion only after the isolated app has quit.
python3 docs/qa/2026-09-07-0.8.0/scripts/seed_gui_fixtures.py \
  --database '/tmp/macparakeet-080-qa/isolated-home/Library/Application Support/MacParakeet/macparakeet.db'
```

The database must already exist with the current migrated schema. There is no
default database path, migration, overwrite, cleanup, or provider configuration.
All five UUIDs are deterministic. Existing IDs are preserved, including edits
made during QA; rerunning the script will not reset those edits. Inserts run in
one transaction with foreign keys enabled. A missing database path fails without
creating a database. `--dry-run` opens SQLite in read-only mode.

## Records and expected content

Search Library for `QA 080` to find all three file transcripts. Their fixed
creation time is 2026-09-07 12:00:00 UTC, so they need not appear above newer
recordings. No source audio paths are attached and no audio files are created.

| Record | UUID | Content |
| --- | --- | --- |
| QA 080 ALPHA | `ec5dab6e-6ac9-5b56-b5af-9fab22f85c2d` | 240 timed words; `ALPHA`, `copper lantern`, `QA ALPHA Speaker` |
| QA 080 BRAVO | `83871657-faed-58ba-972f-63c3e00b5b3f` | 240 timed words; `BRAVO`, `silver meadow`, `QA BRAVO Speaker` |
| QA 080 LONG 10000 | `4e4ce504-9e92-5be0-ac78-f3c3261e2738` | 10,000 timed words; sentences `0001` through `1000`; alternating `QA LONG Speaker One` and `QA LONG Speaker Two` |
| QA Markdown Preview | `e6112ec4-0872-5bb6-bc9b-7a6881c4fd3d` | Saved result attached to ALPHA; heading `QA rich Markdown summary` |
| QA saved Markdown chat | `03539adb-ac35-5521-9f3f-d22abcdd5419` | Saved conversation attached to ALPHA; assistant heading `QA assistant Markdown reply` |

Each sentence contains exactly ten words and ends with a period. Source
segmentation therefore yields 24 timed rows for ALPHA/BRAVO and 1,000 for LONG,
crossing the 400-row lazy-layout threshold. Word timing advances by 400 ms;
the last LONG row starts at 66:36. These are artificial timings, not measured
speech or playback evidence.

## GUI checks

1. Open ALPHA, choose **Timed**, and inspect the first and last rows. Only ALPHA
   words and `QA ALPHA Speaker` should appear. Copy a timed row and confirm its
   text matches that row. Open BRAVO and repeat; its speaker and `silver meadow`
   text must replace ALPHA content. Repeat in both directions. Equal word counts
   intentionally exercise record identity without a word-count difference.
2. Open LONG and choose **Timed**. Scroll down while the pointer remains over the
   transcript, reach sentence `1000`, then scroll back up. Use Find for `1000` or
   `violet compass`, resize the window, and inspect speaker headers and wrapped
   rows. Record responsiveness and whether selection or hover interrupts scrolling.
3. Open ALPHA's **QA Markdown Preview** result tab. Inspect heading hierarchy,
   bold/italic/inline code, the three-column table, JSON code block, quotation,
   numbered list, task list, and `QA MARKDOWN COMPLETE` end marker. Resize the pane
   to check table wrapping and horizontal overflow. Repeat with the alternate
   appearance when convenient.
4. Select text in a paragraph, code block, and table cell. Check the table's Copy
   and Download actions, including cancelling the save panel. Use the result's
   **Copy** and **Export → Markdown (.md)** actions and compare with that fixture's
   `summaries.content` or `RICH_MARKDOWN` in the script. Plain-text export may
   intentionally remove formatting. Record actual clipboard/file content, not
   just button feedback.
5. Open **Chat** and the saved conversation if it is not already selected. Confirm
   the user question and rich assistant reply render, then switch tabs and reopen.
   Expected visible/accessibility content includes `QA assistant Markdown reply`,
   table cells `Copper lantern appears only in ALPHA`, and `QA MARKDOWN COMPLETE`.
   Check native text selection and link labels `QA HTTPS link` / `QA blocked file
   link`; the file link must not open a local file. Actual VoiceOver traversal and
   AX roles still require runtime inspection; visible text alone is not proof.

Opening saved results should not require generating another response. Do not
press Regenerate or send a chat message as part of this fixture-only check.
If configuration gates prevent viewing existing content, record the obstruction.

Static fixtures do not force an asynchronous cache build to remain pending, nor
guarantee that navigation reuses the same SwiftUI view identity. The deterministic
`TranscriptSegmentCacheTests` cover that ordering. Saved Markdown does not prove
streaming, cancellation, or provider behavior. Missing audio deliberately leaves
playback, seek correctness, retranscription, and capture QA to separate fixtures.

## Encoding and validation

Schema was inspected read-only from the isolated running-app database. The script
uses GRDB's 16-byte UUID BLOB representation despite SQLite columns declaring
`TEXT`, UTC date strings with milliseconds, and JSON text for Codable arrays.
`WordTimestamp` uses `word/startMs/endMs/confidence/speakerId`; `SpeakerInfo` uses
`id/label`; `ChatMessage` uses `role/content` with `user` and `assistant` roles.
Saved outputs belong to `summaries` (`PromptResult`), and conversations belong to
`chat_conversations`; no obsolete inline `chatMessages` data is populated.

Source references: `Models/Transcription.swift`, `Models/PromptResult.swift`,
`Models/ChatConversation.swift`, `Models/LLMTypes.swift`, and
`Database/DatabaseManager.swift` under `Sources/MacParakeetCore`. GRDB's pinned
`Core/Support/Foundation/UUID.swift` confirms UUID byte encoding.

Python validation used a new database containing copies of only the three CREATE
TABLE statements, with no copied user rows:
`/tmp/macparakeet-080-qa/gui-fixture-validation-692koyey/synthetic-schema.db`.
Evidence: sibling `validation.json`. Observed: five inserts, word counts
240/240/10,000, valid JSON shapes, UUID BLOBs, no foreign-key violations, a
byte-identical dry run, no duplicate inserts, and preservation of an intentional
edit on the second run. A missing path did not create a database. This validates
the Python writer and source-matched encoding. A rejected summary insert in a
second synthetic database rolled back all preceding transcript inserts. Native app decoding/rendering
remains the GUI operator's check. The running-app database was not seeded during
fixture preparation.

## Follow-up observation: Library preview after editing

Root observed a saved transcript edit in the detail pane while the Library list
still showed its old preview (`library-list.png`). Source explains the behavior:
`TranscriptionViewModel.updateCurrentTranscriptText` updates `cleanTranscript`
and `isTranscriptEdited`, but leaves `derivedSnippet` unchanged; repository
`save` persists the supplied value. `MeetingRowCard.displayedSnippet` prefers
that saved snippet over the current clean transcript. These paths already exist
at `v0.7.3`; this is not evidence of a newly introduced cache regression.

The snippet is derived display metadata, with no identified contract making it
an immutable historical snapshot. A focused follow-up should consider refreshing
it on edit and revert. ALPHA includes a nonempty `derivedSnippet` to make this
observation reproducible. No product fix is included in the fixture work.
