# Versioned Prompt Manager and Meeting Classification — Implementation Plan

> Status: **COMPLETED** — product and architecture decisions below were
> refined with the owner on 2026-09-05, implementation was explicitly
> approved on 2026-09-05, and the implementation and verification gates were
> completed on 2026-09-05.
>
> Priority: **P1** for prompt versioning/management, **P2** for meeting
> classification and context routing.
>
> Execution baseline on 2026-09-05: plan commit `bb0ebd5d` (code baseline
> `2f11b0cb`).

> Integration note (2026-09-07): The completion claim above records the
> contributor branch, not main/release validation. The earlier three-column and
> primary-meeting-type design below is historical: current authority uses
> transcription labels and a searchable single-list Prompts surface, with
> separate creation/collection sheets. See spec/04 and spec/12. PR #961 integration
> and final verification are tracked separately.

Related authority:

- [`spec/12-processing-layer.md`](../../spec/12-processing-layer.md)
- [`spec/14-per-prompt-inference-settings.md`](../../spec/14-per-prompt-inference-settings.md)
- [`spec/adr/013-prompt-library-multi-summary.md`](../../spec/adr/013-prompt-library-multi-summary.md)
- [`spec/adr/022-transforms-system-wide-rewrite.md`](../../spec/adr/022-transforms-system-wide-rewrite.md)
- [`spec/contracts/cli-json-v1.md`](../../spec/contracts/cli-json-v1.md)
- [`spec/contracts/meeting-artifacts-v1.md`](../../spec/contracts/meeting-artifacts-v1.md)
- [`plans/active/2026-09-03-per-prompt-inference-settings.md`](../active/2026-09-03-per-prompt-inference-settings.md)

## 1. Goal

Turn the existing Prompt Library into one coherent prompt-management system
that supports:

1. Immutable prompt versions and restoration.
2. A native, pleasant Markdown editor with a rendered preview.
3. A deterministic diff between any two versions.
4. User-defined prompt organization categories.
5. Per-prompt LLM inference settings and optional model selection, including
   built-in prompts.
6. The same edit and delete rights for built-in and user-created prompts.
7. Meeting classification through one primary meeting type plus optional
   labels.
8. Prompt availability and auto-run policies based on meeting type.

The design must extend the existing `Prompt` and `PromptResult` architecture.
It must not create a parallel prompt store for meeting prompts or Transforms.

## 2. Verified Current State

### Prompt storage and execution

- `Prompt` is the shared record for result prompts and Transforms. Its current
  `Category` is a technical kind (`result` stored as `summary`, or
  `transform`), not a user-facing organization category.
- The `prompts` table currently owns `name`, `content`, visibility, auto-run,
  ordering, Transform metadata, source auto-run scope, and optional inference
  settings.
- `prompts.content` has been part of upstream since the Prompt Library was
  introduced.
- `prompts.inferenceSettings` was added by the per-prompt inference-settings
  change merged from fork PR #2. The same change added
  `summaries.inferenceSettingsSnapshot`.
- `PromptResult` already stores self-contained snapshots of the prompt name,
  prompt content, extra instructions, meeting notes, output, and effective LLM
  settings.
- Enqueue already snapshots prompt text and requested inference settings.
  Completion persists the adapter-owned effective settings receipt.
- The prompt set is small. Loading it is not a latency-sensitive audio path.

### Built-in behavior

- Result built-ins are currently read-only in `PromptsViewModel` and
  `PromptLibraryView`.
- Built-in deletion is rejected by `PromptRepository`.
- Built-in Transforms are editable and resettable.
- Launch reconciliation overwrites canonical name/content for result built-ins
  but deliberately preserves edited Transform content.

This inconsistent policy is replaced by the uniform lifecycle in this plan.

### Markdown and UI

- Built-in prompt bodies already contain Markdown source.
- The current prompt editor is a plain `TextEditor`.
- `MarkdownContentView` already renders headings, paragraphs, lists, code
  blocks, quotations, thematic breaks, links, and inline emphasis for results
  and chat.
- There is no prompt-version model or prompt diff service.

### Meetings

- A meeting is currently a `Transcription` whose `sourceType == .meeting`.
- Meetings have no business type or general-purpose labels.
- Prompt scoping currently distinguishes only broad transcription sources.
- The manual prompt picker loads every visible result prompt without meeting
  context.
- Meeting auto-run receives only `Transcription.SourceType`.

## 3. Locked Product Decisions

### 3.1 What is versioned

The following values are versioned because they affect the LLM request:

- Markdown prompt content.
- Requested `PromptInferenceSettings`.
- Optional model override.

The following values are **not** versioned:

- Prompt name.
- Technical prompt kind (`result` or `transform`).
- Organization category.
- Visibility.
- Sort order.
- Auto-run and meeting-availability policies.
- Transform shortcut and running label.

Changing only non-versioned metadata updates the prompt row and does not add a
history entry.

### 3.2 One source of truth, no permanent mirror

`prompt_versions` is the sole long-term source of truth for versioned values.
`prompts` stores identity, mutable metadata, and `activeVersionId`.

Runtime reads resolve a prompt in `PromptRepository` with one indexed join:

```sql
SELECT p.*, v.content, v.inferenceSettings, v.modelOverride
FROM prompts p
JOIN prompt_versions v ON v.id = p.activeVersionId
WHERE ...
```

Callers do not perform joins and continue receiving a resolved domain `Prompt`.
The join cost is negligible for a low-tens row set and is preferable to
maintaining two writable copies.

The existing `prompts.content` and `prompts.inferenceSettings` columns may
remain only during a bounded compatibility migration. They are not a permanent
cache or mirror. A later forward-only migration rebuilds `prompts` without
them after every GUI and CLI consumer reads through the version join.

`summaries.promptContent` and `summaries.inferenceSettingsSnapshot` are not
legacy mirrors. They remain permanently because a generated result must be
self-contained even if its prompt or version is later deleted.

### 3.3 Version lifecycle

- Creating a prompt creates version 1 and activates it atomically.
- Saving changed content/settings/model creates exactly one immutable version
  and activates it atomically.
- Saving a no-op creates no version.
- Restoring an old version never moves the active pointer backwards. It copies
  the selected values into a new version and activates that new version.
- Draft changes do not create versions. A version is created only by an
  explicit successful Save.
- Queued work stores `promptId`, `promptVersionId`, and the existing value
  snapshots. A later edit cannot change queued, failed, retry, or completed
  work.
- Result regeneration continues using the historical result snapshot unless
  the user explicitly chooses to regenerate with the current prompt version.

### 3.4 Built-ins have the same rights

Built-in and user-created prompts can both be:

- Renamed.
- Edited.
- Reconfigured.
- Recategorized.
- Hidden.
- Assigned to meeting types.
- Deleted.

`isBuiltIn` becomes provenance only. It may drive a badge, canonical comparison,
or restoration affordance, but never an authorization check.

Delete is implemented uniformly as soft deletion with `prompts.deletedAt` so:

- normal reads exclude deleted prompts;
- prompt identity and versions remain recoverable;
- generated results remain untouched;
- the built-in reconciler cannot silently resurrect a deleted built-in.

Permanent purge and a full Trash UI are outside the first delivery. A minimal
Restore action is in scope.

### 3.5 Canonical built-in updates

Canonical definitions retain a stable `canonicalKey` and explicit canonical
revision.

- If a built-in has never been modified or deleted by the user, a newer bundled
  definition creates and activates a `systemUpdate` version.
- If the user has modified, renamed, reconfigured, or deleted the built-in, the
  reconciler leaves the prompt and its history completely untouched.
- For a customized built-in, a newer bundled definition may be shown as
  **MacParakeet update available**, but it is not inserted into user history or
  activated automatically.
- The user may compare against the bundled candidate and explicitly choose
  **Keep mine**, **Adopt MacParakeet version**, or **Create a copy**.
- Explicit adoption creates a new normal history version.

The automatic-update guard is based on persisted provenance, not a content-only
guess. `userCustomizedAt` is set when the user changes the name, versioned
values, or deletes the prompt. Organization, visibility, ordering, and routing
changes are preserved independently and are never overwritten by reconciliation.

### 3.6 LLM settings

- The six implemented inference controls remain typed and provider-neutral:
  temperature, Top P, Top K, maximum output tokens, thinking mode, and
  reasoning effort.
- They become editable on every result prompt, including built-ins.
- Transform execution is extended to accept the same settings rather than
  receiving only a prompt string.
- Blank settings inherit MacParakeet defaults exactly as today.
- Unsupported settings are omitted and surfaced as a compatibility warning;
  they are never reinterpreted.
- `modelOverride` is optional and versioned. `nil` means the active provider's
  selected model.
- The provider remains global in this scope. Per-prompt provider selection is
  deferred until MacParakeet has a first-class multi-provider profile model.
- API keys remain in Keychain and never enter a prompt version.
- If a model override does not exist for the active provider, execution is
  blocked with a repair action; it does not silently use another model.

### 3.7 Meeting classification

- A meeting has zero or one primary `MeetingType`.
- A meeting may have zero or more `MeetingLabel` values.
- Meeting type drives prompt availability and auto-run.
- Labels are descriptive facets used for search, filters, and organization in
  v1. They do not drive prompt routing in v1.
- Types and labels already in use are archived rather than destructively
  deleted.
- An unclassified meeting is a supported state.
- Calendar-based automatic classification is out of scope for v1.

## 4. Target Data Model

All migrations are registered forward-only in `DatabaseManager`. Older shipped
migrations are never edited.

### 4.1 `prompts`

Keep:

```text
id
name
category                 // technical result/transform kind
isBuiltIn                // provenance only
isVisible
isAutoRun                // retained during policy migration
sortOrder
keyboardShortcut
runningLabel
appliesToSources         // retained for non-meeting source behavior
createdAt
updatedAt
```

Add:

```text
activeVersionId UUID
collectionId UUID nullable
canonicalKey TEXT nullable
lastAppliedCanonicalRevision INTEGER nullable
userCustomizedAt DATETIME nullable
deletedAt DATETIME nullable
```

Remove after the bounded compatibility window:

```text
content
inferenceSettings
```

### 4.2 `prompt_versions`

```text
id UUID PRIMARY KEY
promptId UUID NOT NULL REFERENCES prompts(id) ON DELETE CASCADE
versionNumber INTEGER NOT NULL
content TEXT NOT NULL
inferenceSettings TEXT nullable        // JSON PromptInferenceSettings
modelOverride TEXT nullable
origin TEXT NOT NULL                   // user, restore, systemUpdate, import
changeNote TEXT nullable
createdAt DATETIME NOT NULL

UNIQUE(promptId, versionNumber)
INDEX(promptId, versionNumber DESC)
```

`activeVersionId` must resolve to a version belonging to the same prompt.
Because a cross-table ownership check is awkward as a plain SQLite foreign key,
the editing service enforces it inside the same write transaction and repository
tests cover direct invalid writes.

### 4.3 `prompt_results` / `summaries`

Add nullable provenance fields:

```text
promptId UUID nullable
promptVersionId UUID nullable
modelSnapshot TEXT nullable
```

Keep every existing name/content/settings snapshot. Foreign keys use `ON DELETE
SET NULL`, or remain intentionally unenforced if preserving results across a
later permanent prompt purge requires it. The snapshots remain authoritative
for historical display and regeneration.

### 4.4 Prompt organization

```text
prompt_collections
- id UUID PRIMARY KEY
- name TEXT NOT NULL UNIQUE COLLATE NOCASE
- colorToken TEXT nullable
- sortOrder INTEGER NOT NULL
- createdAt DATETIME NOT NULL
- updatedAt DATETIME NOT NULL
```

One prompt has zero or one organization collection. Deleting a collection sets
`prompts.collectionId` to `NULL`; it never deletes prompts.

The Swift name is `PromptCollection`, not `PromptCategory`, to avoid collision
with the existing technical `Prompt.Category`.

### 4.5 Meeting classification

```text
meeting_types
- id UUID PRIMARY KEY
- name TEXT NOT NULL UNIQUE COLLATE NOCASE
- colorToken TEXT nullable
- iconName TEXT nullable
- sortOrder INTEGER NOT NULL
- isArchived BOOLEAN NOT NULL
- createdAt DATETIME NOT NULL
- updatedAt DATETIME NOT NULL

meeting_labels
- id UUID PRIMARY KEY
- name TEXT NOT NULL UNIQUE COLLATE NOCASE
- colorToken TEXT nullable
- sortOrder INTEGER NOT NULL
- isArchived BOOLEAN NOT NULL
- createdAt DATETIME NOT NULL
- updatedAt DATETIME NOT NULL

transcriptions.meetingTypeId UUID nullable

transcription_meeting_labels
- transcriptionId UUID REFERENCES transcriptions(id) ON DELETE CASCADE
- labelId UUID REFERENCES meeting_labels(id)
- PRIMARY KEY(transcriptionId, labelId)
```

`meetingTypeId` uses `ON DELETE SET NULL`. Normal product behavior archives a
type rather than deleting it.

### 4.6 Meeting prompt policies

```text
prompt_meeting_policies
- id UUID PRIMARY KEY
- promptId UUID NOT NULL REFERENCES prompts(id) ON DELETE CASCADE
- scopeKind TEXT NOT NULL              // all or type
- meetingTypeId UUID nullable
- isAvailable BOOLEAN NOT NULL
- isAutoRun BOOLEAN NOT NULL
- sortOrder INTEGER nullable
- createdAt DATETIME NOT NULL
- updatedAt DATETIME NOT NULL
```

Constraints:

- `scopeKind == all` requires `meetingTypeId == NULL`.
- `scopeKind == type` requires a non-null `meetingTypeId`.
- At most one `all` rule per prompt.
- At most one rule per `(promptId, meetingTypeId)`.
- An exact type rule takes precedence over the prompt's `all` rule.
- No matching rule means unavailable for that meeting.
- `isVisible == false` is still the global kill switch.
- Non-meeting sources ignore meeting policies and retain their existing
  `appliesToSources` behavior.

Migration creates an `all` policy for every existing result prompt, preserving
its current meeting availability and whether it auto-runs for `.meeting`.

## 5. Domain and Repository Design

### 5.1 Resolved prompt model

Separate persisted rows from the execution-facing value:

```text
PromptRecord           // identity and mutable metadata from prompts
PromptVersion          // immutable version row
Prompt                 // resolved domain value returned to existing callers
```

`PromptRepository` owns the active-version join and returns `Prompt`. Existing
generation and Transform callers do not gain database knowledge.

### 5.2 Repositories

Follow the database rule of one repository per table:

- `PromptRepository`
- `PromptVersionRepository`
- `PromptCollectionRepository`
- `MeetingTypeRepository`
- `MeetingLabelRepository`
- `TranscriptionMeetingLabelRepository`
- `PromptMeetingPolicyRepository`

`TranscriptionRepository` owns only the `meetingTypeId` column and SQL-level
library filtering involving the transcription row.

### 5.3 Multi-table services

Add services for cross-table transactions:

- `PromptEditingService`
  - create prompt + V1 + active pointer;
  - save metadata and/or one new version;
  - restore as a new version;
  - soft delete/restore;
  - adopt or copy a canonical candidate.
- `BuiltInPromptReconciliationService`
  - compare canonical revisions;
  - update only untouched built-ins;
  - preserve all user metadata;
  - never resurrect customized or deleted prompts.
- `MeetingClassificationService`
  - set or clear a type;
  - add/remove/replace labels atomically;
  - refresh materialized meeting artifacts after commit.
- `PromptApplicabilityResolver`
  - resolve manual availability and auto-run from source plus meeting type;
  - return an explanation suitable for UI and diagnostics.

### 5.4 Diff service

Add a pure Core `PromptDiffService`:

- input: two `PromptVersion` values;
- line-level diff of Markdown source;
- word-level refinement within modified lines;
- Unicode-safe ranges;
- structured changes for inference settings and model override;
- no AppKit or SwiftUI dependency.

Restoration is not part of the diff service; it remains an explicit editing
service transaction.

## 6. Prompt Manager UX

Create one large, resizable Prompt Manager reachable from:

- the result-generation popover;
- Meetings / After Each Meeting;
- the Transforms surface;
- an appropriate Settings or application-menu entry.

Do not add a second LLM-settings implementation to the generation popover.

### 6.1 Layout

Use a three-column layout at comfortable widths:

```text
+ Categories -----+ Prompts -------------+ Detail ----------------------+
| All              | Search          + New | Edit | Preview | History     |
| Built-ins        | Summary       Auto   |                              |
| Meetings         | Customer recap       | Markdown source | preview    |
| Writing          | Polish        Built  | LLM settings                 |
| Learning         |                       | Meeting availability         |
+------------------+-----------------------+------------------------------+
```

- Left: organization categories and smart filters.
- Middle: searchable prompt list.
- Right: selected-prompt editor and history.
- At the minimum supported width, collapse source/preview into an
  **Edit / Preview** segmented control.

Smart filters:

- All.
- Built-ins.
- My prompts.
- Result prompts.
- Transforms.
- Hidden.
- Deleted, via a minimal Trash entry.

Badges:

- Active version number.
- Built-in provenance.
- Auto-run.
- Custom LLM settings.
- Model override.
- Canonical update available.

### 6.2 Markdown editing

- Store and send the exact Markdown source; preview does not rewrite it.
- Reuse the rendering behavior of `MarkdownContentView`, extracting shared
  parsing/rendering pieces if needed.
- Support headings, lists, code, block quotes, links, emphasis, and horizontal
  rules.
- Surface supported template variables such as `{{transcript}}` and
  `{{userNotes}}` as insertable tokens.
- Validate unknown template variables before Save.
- Confirm before discarding unsaved changes.
- Never create history during typing or preview refresh.

### 6.3 History and comparison

- Timeline of versions with version number, date, origin, and optional note.
- Select any two versions as **From** and **To**.
- Unified diff by default; side-by-side mode as an option.
- Show Markdown source changes and a separate structured settings comparison.
- **Restore this version** creates a new version.
- For a customized built-in, allow comparison with a bundled canonical
  candidate without inserting that candidate into the history.

### 6.4 LLM settings

- Collapsed **Generation settings** section using the existing validation and
  provider capability resolver.
- `Reset to MacParakeet defaults` clears the six inference overrides.
- Optional model picker defaults to **Use active model**.
- Unsupported or unavailable choices show actionable, non-blocking guidance in
  the editor; execution is blocked only for an unavailable explicit model.
- The generation popover shows a compact read-only summary of the resolved
  settings and model.

## 7. Meeting Classification UX

### 7.1 Type and labels

Expose classification in three places:

1. Before or during recording, so the type can affect auto-run.
2. The processing/completed meeting detail header.
3. Recent meeting rows and their context menus.

UI behavior:

- One type picker with **Unclassified** as a valid value.
- Token-style multi-select labels with inline creation.
- Type shown as the primary badge on a meeting row.
- Show up to two labels, then `+N`.
- Keyboard and VoiceOver support for create, assign, remove, and archive.

Types and labels are local user data. Their names are not sent to telemetry.

### 7.2 Library and Meetings filters

Add SQL-backed filters before pagination:

- All types.
- Unclassified.
- One or more selected types.
- One or more labels.
- Explicit label matching mode if both ANY and ALL are later exposed; v1 uses
  ANY.

Do not filter a paginated in-memory page after `LIMIT/OFFSET`, because that
would make counts and `hasMore` incorrect.

### 7.3 Classification timing and recovery

The type must be available before prompt auto-run. Full UX threads an optional
`meetingTypeId` through:

- the meeting start draft;
- `MeetingRecordingFlowCoordinator`;
- recording output;
- the crash-recovery lock/sidecar as transport data;
- the durable `Transcription` row once its stub exists.

SQLite becomes canonical as soon as the transcription stub is created. Capture
metadata sidecars remain capture provenance, not the mutable classification
source of truth.

Changing a type after generation:

- never deletes existing results;
- updates the manual prompt picker immediately;
- never triggers auto-run retroactively;
- may offer an explicit **Generate missing results** action.

## 8. Prompt Availability and Auto-Run

Introduce a `PromptAvailabilityContext`:

```text
sourceType
meetingTypeId?
```

The central resolver returns:

```text
isAvailableManually
isAutoRunEligible
reason
matchedPolicy
```

Meeting resolution order:

1. Prompt must not be deleted and must be visible.
2. Exact meeting-type policy wins when present.
3. Otherwise use the `all` meeting policy.
4. Without either policy, the prompt is unavailable.
5. Auto-run requires both availability and the resolved policy's `isAutoRun`.

Non-meeting resolution continues using visibility, technical kind, global
auto-run, and `appliesToSources` until a later unified source-policy migration
is justified.

The same resolver must drive:

- manual result prompt selection;
- After Each Meeting configuration;
- post-transcription auto-run;
- CLI list/run eligibility;
- explanatory UI when no prompt is available.

Queue receipts capture the resolved prompt/version/settings. Changing the
meeting type after enqueue does not mutate work already queued.

## 9. CLI and Artifact Contracts

The CLI is a public, semver-tracked surface. Changes are additive first.

### 9.1 Prompt commands

Proposed commands/options:

```text
prompts history <prompt> [--json]
prompts show <prompt> [--version N] [--json]
prompts diff <prompt> --from N --to N [--json]
prompts restore <prompt> --version N [--json]
prompts delete <prompt> [--json]
prompts restore-deleted <prompt> [--json]
prompts set <prompt> --model <name>|--active-model
prompts set <prompt> --meeting-type <type>
prompts set <prompt> --all-meeting-types
```

Equivalent version/settings behavior applies to `transforms` commands. Existing
JSON fields remain compatible; new version/provenance fields are additive.

### 9.2 Meeting commands

```text
meetings types list|add|rename|archive
meetings labels list|add|rename|archive
meetings classify <meeting> --type <id-or-name>|none
                            --add-label <id-or-name>
                            --remove-label <id-or-name>
meetings list --type <id-or-name> --label <id-or-name>
```

### 9.3 Materialized meeting artifacts

Add optional type and label snapshots to:

- `manifest.json` meeting metadata;
- `transcript.json`;
- `meeting.md` frontmatter/details;
- CLI meeting list/show/export JSON.

Changing classification refreshes materialized artifacts after the database
transaction. It does not rewrite capture-provenance metadata.

Update together:

- `spec/contracts/cli-json-v1.md`;
- `spec/contracts/meeting-artifacts-v1.md`;
- `Sources/CLI/CHANGELOG.md`;
- `integrations/README.md`;
- dynamic CLI spec output and snapshot tests.

## 10. Implementation Slices

### Slice 0 — Governing decisions and contracts

- Amend ADR-013 for immutable versions, uniform built-in rights, soft deletion,
  and guarded canonical updates.
- Amend ADR-022 for versioned Transform content/settings.
- Update specs 01, 11, 12, and 14.
- Lock migration compatibility and CLI JSON strategy before schema changes.

Exit gate: schema, deletion semantics, canonical-update guard, and execution
snapshot rules are approved.

### Slice 1 — Version persistence foundation

- Add version/provenance schema and forward-only migrations.
- Backfill V1 for every existing prompt.
- Add record types and repositories.
- Add the active-version join.
- Introduce `PromptEditingService` with atomic create/edit/restore/delete.
- Preserve temporary legacy columns only for the documented compatibility
  window.

Exit gate: upgraded and empty databases resolve the same current prompts as
before, and no caller performs its own join.

### Slice 2 — Execution provenance and built-ins

- Add `promptId`, `promptVersionId`, and model snapshot to pending generations
  and results.
- Keep historical value snapshots.
- Replace built-in authorization guards with uniform behavior.
- Replace launch reconciliation with canonical-revision reconciliation.
- Add soft delete/restore and prevent resurrection.
- Extend Transform execution to accept version settings and model choice.

Exit gate: built-ins and user prompts have identical CRUD rights; queue,
retry, regenerate, and Transform execution remain immutable after enqueue.

### Slice 3 — Prompt Manager and Markdown

- Build the three-column manager shell.
- Add search, smart filters, collections, and Trash.
- Add Markdown source/preview editing.
- Extract reusable Markdown rendering components as required.
- Add provider/model compatibility presentation.

Exit gate: all prompt kinds can be managed through one coherent surface without
removing their contextual entry points.

### Slice 4 — Version history and diff

- Add history timeline and version detail.
- Add deterministic line/word diff.
- Add structured settings/model diff.
- Add restore-as-new-version.
- Add customized built-in versus bundled-candidate comparison.

Exit gate: any two persisted versions can be compared and any old version can
be restored without history mutation.

### Slice 5 — Meeting types and labels

- Add classification schema and repositories.
- Add classification service and artifact refresh.
- Add detail, live, row, and filter UX.
- Thread the selected type through start, stop, recovery, and stub creation.
- Add SQL filters before pagination.

Exit gate: classification survives normal completion and crash recovery, and
materialized artifacts match SQLite.

### Slice 6 — Contextual prompt routing

- Add meeting policies and migration defaults.
- Add `PromptApplicabilityResolver`.
- Contextualize the manual picker.
- Replace the current all-meetings auto-note chips with type-aware policy
  management.
- Route auto-run through the same resolver.

Exit gate: manual availability and auto-run produce the same answer for the
same meeting context.

### Slice 7 — CLI, compatibility cleanup, and rollout

- Add version, classification, and policy CLI commands.
- Update public contracts, changelog, and integration docs.
- Remove temporary legacy prompt columns through a new table-rebuild migration
  once all supported consumers use active versions.
- Run accessibility and manual end-to-end QA.
- Run the full Swift test suite once as the final gate.

## 11. Test Plan

### Model and pure logic

- Version equality/no-op detection.
- Monotonic version numbers.
- Restore creates a new version.
- Markdown/template validation.
- Unicode line and word diff.
- Structured settings/model diff.
- Applicability: exact type, all types, unavailable, and unclassified.

### Database and migrations

- Empty database migration.
- Upgrade from the pre-version schema with and without inference settings.
- One V1 per existing result and Transform prompt.
- Active-version ownership and referential integrity.
- No permanent content/settings mirror after compatibility cleanup.
- Collection deletion sets prompt collection to nil.
- Type deletion/set-null and archive behavior.
- Label join uniqueness and cascades.
- Meeting filters combined with search, status, ordering, pagination, and
  `hasMore`.
- Concurrent app/CLI migration serialization remains intact.

### Built-in reconciliation

- Untouched built-in adopts a newer canonical revision.
- Edited content blocks automatic canonical update.
- Edited name blocks automatic canonical update.
- Edited settings/model block automatic canonical update.
- Deleted built-in is not resurrected.
- Organization and routing metadata are never overwritten.
- Explicit adoption creates one new version.
- Creating a copy produces a non-built-in prompt with its own V1.

### Generation and Transforms

- Manual, auto-run, retry, and regenerate capture the intended version.
- Editing after enqueue cannot change a pending run.
- Effective settings/model receipt remains honest after provider filtering.
- Unavailable explicit model blocks before network execution.
- Transform built-ins and customs use version settings equally.
- Historical results remain readable after prompt soft deletion.

### UI and accessibility

- Unsaved-edit protection.
- Keyboard-only navigation across all three columns.
- VoiceOver labels and values for filters, versions, diff lines, type picker,
  labels, and settings.
- Markdown preview updates without saving.
- No-op save does not add history.
- Narrow-width Edit/Preview fallback.
- Built-in badge never disables editing or deletion.

### Meetings, artifacts, and CLI

- Classification before/during capture reaches the durable meeting row.
- Crash recovery retains the selected type.
- Reclassification refreshes artifacts but not capture provenance.
- Type change after enqueue does not alter the queued prompt set.
- No retroactive auto-run.
- CLI human and JSON outputs for versions, diff, types, labels, and policies.
- Additive JSON compatibility and dynamic spec parity.

Focused iteration should use relevant filters such as:

```bash
swift test --filter PromptRepositoryTests
swift test --filter PromptsViewModelTests
swift test --filter PromptResultsViewModelTests
swift test --filter TransformsViewModelTests
swift test --filter TranscriptionRepositoryTests
swift test --filter MeetingsWorkspaceViewModelTests
swift test --filter MeetingRecordingRecoveryServiceTests
swift test --filter MeetingArtifactStoreTests
swift test --filter PromptsCommandTests
swift test --filter MeetingsCommandTests
```

Run full `swift test` at most once, as the final code-change gate.

## 12. Acceptance Criteria

1. Every existing prompt receives one active V1 without behavior or data loss.
2. `prompt_versions` is the only long-term source of prompt content and
   versioned LLM settings.
3. Prompt consumers receive resolved prompts through repositories and contain
   no ad hoc joins.
4. Prompt renaming does not create a version.
5. Editing content, settings, or model creates exactly one version; a no-op
   creates none.
6. Restoring V1 while V3 is active creates V4 with V1's versioned values.
7. Built-ins and user prompts have identical edit, rename, categorize, hide,
   and delete rights.
8. A deleted built-in does not return after relaunch or reconciliation.
9. A newer canonical definition updates only an untouched built-in.
10. A customized built-in remains byte-for-byte unchanged until explicit user
    action.
11. Markdown source is preserved and its preview correctly renders supported
    block and inline constructs.
12. Any two versions can be compared, including inference settings and model.
13. Queued work retains its original version even after edits or meeting-type
    changes.
14. A meeting can have zero/one type and multiple labels.
15. Prompt availability and auto-run can differ by meeting type and are decided
    by one shared resolver.
16. An unclassified meeting receives only policies applicable to all meetings.
17. Changing classification never deletes historical results or triggers
    implicit retroactive generation.
18. Library and Meetings type/label filters remain correct under pagination.
19. Meeting artifacts and CLI output expose current classification additively.
20. No prompt, version content, model name, meeting type name, or label name is
    added to telemetry or the `llm_runs` metadata ledger.

## 13. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Active version points to another prompt's version | Editing-service transaction plus direct-write repository tests |
| Version explosion from autosave | Explicit Save only; no version on typing or no-op |
| Legacy column and version drift | Bounded compatibility window, then remove legacy columns; no permanent mirror |
| Built-in resurrection or overwrite | Soft deletion plus persisted customization/canonical revision guard |
| Queue reads the active version too late | Snapshot ID and values at enqueue |
| Model override becomes invalid after provider change | Capability check and blocking repair action before execution |
| Manual picker and auto-run disagree | One `PromptApplicabilityResolver` |
| Meeting classified too late for auto-run | Allow type selection before/during recording and persist through recovery |
| Pagination lies after label filtering | SQL joins/EXISTS before LIMIT/OFFSET |
| Artifact sidecar becomes a second source of truth | SQLite canonical; artifacts regenerated projections only |
| Public CLI JSON breaks agents | Additive fields first, contract/changelog/spec tests in the same PR |
| User data leaks through telemetry | Keep content and user-defined names out of telemetry and `llm_runs` |

## 14. Explicitly Deferred

- Per-prompt provider selection and multiple credential profiles.
- Arbitrary provider request JSON.
- Automatic LLM classification of meetings.
- Calendar-title classification rules.
- Label-driven prompt Boolean expressions (`ANY`/`ALL`/`NOT`).
- Prompt branching, merging, collaboration, or remote synchronization.
- Permanent purge and a feature-rich Trash.
- Workflow/agent step chaining.
