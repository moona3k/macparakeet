# Lifetime Dictation Stats (Issue #124)

## Problem

Reported in [#124](https://github.com/moona3k/macparakeet/issues/124): user cleared their dictation history and watched their voice stats reset from "thousands of words" to "2 minutes spoken." Privacy housekeeping should not double as a stats reset.

Root cause: `DictationRepository.stats()` (`Sources/MacParakeetCore/Database/DictationRepository.swift:181`) is pure SQL aggregation over the `dictations` table — totals are *derived from rows that the user just deleted*. There is no persistent counter.

## Design Goals

1. Headline lifetime numbers — total words, total time, total dictations, longest dictation — survive any deletion path (`deleteAll`, `deleteHidden`, `delete(id:)`, future single-row deletes from history UI).
2. No new "Total ever" UI affordance. The existing "Your Voice Stats" card and CLI just start meaning "lifetime" instead of "currently in your history."
3. Do not regress streak / this-week semantics (those are inherently about *recent activity*, not lifetime, so keep them derived from current rows).
4. Stay invisible at the call-site level. Existing callers of `repo.save(dictation)` keep working unchanged.
5. Backfill on first launch after upgrade so existing users do not see a one-off reset to zero. (We cannot recover what was already lost in #124, but we can honor what is currently still in the DB.)

## Non-Goals

- No per-event archival log. We do not need to reconstruct a historical timeline.
- No public/private split for lifetime totals. Hidden dictations *do* count — privacy is "no transcript stored," not "no metric ever derived."
- No ADR. This is a localized data-model fix, not an architectural inflection.
- No new telemetry event.

## Schema

New table, populated by migration `v0.7.4-lifetime-dictation-stats`:

```sql
CREATE TABLE lifetime_dictation_stats (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    totalCount INTEGER NOT NULL DEFAULT 0,
    totalDurationMs INTEGER NOT NULL DEFAULT 0,
    totalWords INTEGER NOT NULL DEFAULT 0,
    longestDurationMs INTEGER NOT NULL DEFAULT 0,
    updatedAt TEXT NOT NULL
);
```

- Single-row pattern enforced by `CHECK (id = 1)`. The migration immediately calls `recomputeLifetimeStats(db:)` (the shared helper, see below), which uses `INSERT OR REPLACE` and seeds the row from existing data. After migration, the row is guaranteed present and every hot-path update is a plain `UPDATE … WHERE id=1`.

## Increment Path

In `DictationRepository.save()`. **Ordering is load-bearing**: fetch existing → write new → conditional counter touch. After `dictation.save(db)`, re-fetching would return the new values and break the delta math, so the existing-state fetch *must* happen first. Comment this in code.

```swift
public func save(_ dictation: Dictation) throws {
    try dbQueue.write { db in
        // MUST fetch existing state BEFORE dictation.save(db); the delta path
        // depends on the pre-write status / durationMs / wordCount.
        let existing = try Dictation.fetchOne(db, key: dictation.id)
        try dictation.save(db)

        switch (existing?.status, dictation.status) {
        case (.some(.completed), .completed):
            // Mutating an already-counted row (e.g. future "edit transcript" path).
            // Apply the delta so totals don't drift. longestDurationMs stays a
            // high-water mark — never decrements.
            // existing is guaranteed non-nil on this branch (matched .some(.completed)).
            let prior = existing!
            try applyLifetimeDelta(
                db: db,
                durationDelta: dictation.durationMs - prior.durationMs,
                wordDelta: dictation.wordCount - prior.wordCount,
                newDurationMs: dictation.durationMs
            )
        case (_, .completed):
            // Fresh insert at .completed, or transition from .recording / .processing
            // / .error → .completed. Increment by full row.
            try incrementLifetimeStats(
                db: db,
                durationMs: dictation.durationMs,
                wordCount: dictation.wordCount
            )
        default:
            break
        }
    }
}
```

Both helpers run a single `UPDATE` against the singleton row and assert `db.changesCount == 1` afterwards — a missing or extra row throws `LifetimeStatsError.singletonMissing` instead of silently corrupting totals (real risk in tests where someone manually wipes the table).

`incrementLifetimeStats`:
```sql
UPDATE lifetime_dictation_stats
SET totalCount        = totalCount + 1,
    totalDurationMs   = totalDurationMs + :durationMs,
    totalWords        = totalWords + :wordCount,
    longestDurationMs = MAX(longestDurationMs, :durationMs),
    updatedAt         = :now
WHERE id = 1;
```

`applyLifetimeDelta` (only fires on completed→completed mutation):
```sql
UPDATE lifetime_dictation_stats
SET totalDurationMs   = totalDurationMs + :durationDelta,
    totalWords        = totalWords + :wordDelta,
    longestDurationMs = MAX(longestDurationMs, :newDurationMs),
    updatedAt         = :now
WHERE id = 1;
```
Note: `totalCount` does not change on a delta path (we already counted this dictation). `longestDurationMs` is a high-water mark — even if the row is shrunk, the lifetime max never decreases. This asymmetry is intentional and documented in the code comment.

Properties this gives us:
- **Atomic.** Fetch + insert/update + counter touch all run inside one GRDB write transaction. Either all commits or all rolls back.
- **Drift-resistant.** Re-saving a completed row with mutated `wordCount` or `durationMs` updates the lifetime totals by delta, not skipped. (Today's code never does this, but a future "edit transcript" feature won't silently break stats.)
- **Idempotent on identical re-save.** Saving a completed row with the same values produces zero deltas → no-op.
- **Forward-compatible.** If we later split save into `recording → completed` transitions, the increment fires exactly once on the transition.
- **Serialized.** GRDB `DatabaseQueue` enforces single-writer; no concurrency bug surface.
- **Loud on corruption.** Singleton row missing? Throws, not silently drops increments.

## Read Path

`stats()` becomes a small composition:

1. `SELECT totalCount, totalDurationMs, totalWords, longestDurationMs FROM lifetime_dictation_stats WHERE id = 1` — lifetime totals.
2. `SELECT SUM(CASE WHEN hidden = 0 THEN 1 ELSE 0 END) FROM dictations WHERE status = 'completed'` — current `visibleCount` (unchanged semantic: "what's actually in your history right now").
3. Existing date query → `weeklyStreak` and `dictationsThisWeek` (unchanged).
4. `averageDurationMs` derived from lifetime totals in Swift, with explicit divide-by-zero guard: `totalCount > 0 ? totalDurationMs / totalCount : 0`.

`DictationStats` struct is unchanged. Field semantics shift:

| Field | Before | After |
|---|---|---|
| `totalCount` | rows currently in DB | lifetime completed dictations |
| `totalDurationMs` | sum of current rows | lifetime sum |
| `totalWords` | sum of current rows | lifetime sum |
| `longestDurationMs` | max of current rows | lifetime max |
| `averageDurationMs` | derived from current rows | derived from lifetime totals |
| `visibleCount` | non-hidden current rows | unchanged |
| `weeklyStreak` | from current rows | unchanged (derived, not lifetime — "are you on a streak right now?") |
| `dictationsThisWeek` | from current rows | unchanged |

Computed properties (`averageWPM`, `timeSavedMs`, `booksEquivalent`, `emailsEquivalent`) automatically follow because they read `totalWords` / `totalDurationMs`.

## UI Impact

`Sources/MacParakeet/Views/History/DictationHistoryView.swift:128`:
```swift
subtitle: "\(stats.totalCount) dictation\(stats.totalCount == 1 ? "" : "s")"
```
This subtitle now reads "lifetime dictations" rather than "rows in your history."

**Conscious tradeoff acknowledged from review:** right after a "Clear All Dictations" action, the stats card will show e.g. "847 dictations · 12 hours" while the history list directly below it is empty. This is intentional and matches the user request in #124 — they explicitly want lifetime numbers preserved through deletion. The mismatch is the *correct* signal ("here's your lifetime voice output; here's your current retained history"). If real users find this confusing post-ship, the cleanest follow-up is to add a parallel `lifetimeXxx` field set on `DictationStats` and split the UI into a lifetime card + a current-history card. Not doing that now — extra surface area for a hypothetical complaint.

`Sources/CLI/Commands/StatsCommand.swift:34` prints `Total: \(stats.visibleCount)` — leave as-is. CLI "Total" stays "currently visible." If we want to also surface lifetime via CLI, that's a follow-up; not required to fix this issue.

## Tests

**Refactor the backfill into a shared helper.** Extract `recomputeLifetimeStats(db: Database, now: Date = Date()) throws` — note the parameter is `GRDB.Database` (mid-transaction handle), **not** `DatabaseQueue`. Callers are responsible for opening the write transaction (the migration is already inside one; tests wrap with `try dbQueue.write { db in … }`). Trying to nest `dbQueue.write` would deadlock GRDB.

The recompute helper uses `INSERT OR REPLACE` (not `UPDATE`) so it is **bulletproof against a missing or corrupted singleton row** — it always lands the row in the correct state regardless of prior state. This is the deliberate counterpart to the increment-path helpers, which `UPDATE` and assert `db.changesCount == 1` to fail loudly on invariant violations:

| Path | SQL pattern | Behavior on missing row |
|---|---|---|
| `incrementLifetimeStats` (hot path) | `UPDATE … WHERE id=1` | Throws `singletonMissing` — invariant violated, fail loudly |
| `applyLifetimeDelta` (hot path) | `UPDATE … WHERE id=1` | Throws `singletonMissing` — invariant violated, fail loudly |
| `recomputeLifetimeStats` (recovery / migration) | `INSERT OR REPLACE` | Self-heals — restores the row from current `dictations` |

Three callers, one source of truth: (a) migration calls it for backfill, (b) test 13 calls it directly to cross-check incremental accumulation, (c) the documented recovery recipe is "call `recomputeLifetimeStats`."

New file: `Tests/MacParakeetTests/Database/LifetimeDictationStatsTests.swift`

Cases:
1. **`testLifetimeStatsPersistAfterDeleteAll`** — save 3, deleteAll, expect lifetime totals intact, visibleCount 0.
2. **`testLifetimeStatsPersistAfterDeleteHidden`** — save 1 visible + 1 hidden, deleteHidden, expect lifetime totals reflect both.
3. **`testLifetimeStatsPersistAfterSingleDelete`** — save 2, delete one by id, expect lifetime intact.
4. **`testReSavingCompletedDictationWithSameValuesDoesNotDoubleCount`** — save once with .completed, save again with identical values, expect counts unchanged (delta = 0).
5. **`testReSavingCompletedDictationWithChangedWordCountAppliesDelta`** — save with wordCount=5, save again with wordCount=8, expect totalCount=1 (unchanged) and totalWords=8 (not 13).
6. **`testStatusTransitionToCompletedIncrementsExactlyOnce`** — save with `.recording`, save with `.completed`, expect totalCount=1.
7. **`testErrorStatusDoesNotIncrementLifetime`** — save with `.error`, expect lifetime totals zero.
8. **`testRecordingStatusDoesNotIncrementLifetime`** — save with `.recording`, expect lifetime totals zero.
9. **`testHiddenDictationsContributeToLifetime`** — save 1 hidden, expect totalCount=1, totalWords=N.
10. **`testLongestDurationIsLifetimeMax`** — save 5000ms, delete it, save 1000ms, expect longestDurationMs still 5000.
11. **`testLongestDurationDoesNotDecreaseOnDelta`** — save 5000ms, mutate to 1000ms via re-save, expect longestDurationMs still 5000 (high-water mark).
12. **`testEmptyDatabaseLifetimeStatsAreZero`** — fresh DB, expect all zeros.
13. **`testRecomputeMatchesIncrementalAccumulation`** — save N rows incrementally (driving the increment path), then call `recomputeLifetimeStats()` (driving the recompute SQL), expect identical results. This pins the two paths together — if either drifts, the test fails.
14. **`testIncrementThrowsIfSingletonRowMissing`** — manually `DELETE FROM lifetime_dictation_stats`, attempt `repo.save(.completed)`, expect `LifetimeStatsError.singletonMissing` thrown (transaction rolls back, dictation is not saved either).

Existing tests stay green:
- `DictationStatsQueryTests` — saves rows then reads stats; expectations match because lifetime increments mirror what the old SUM produced. Verified case-by-case: `testStatsTotalCount`, `testStatsTotalWords`, `testStatsLongestDuration`, `testStatsAverageDuration`, `testStatsOnlyCountsCompleted` (`.recording` and `.error` rows skipped by guard).
- `DictationRepositoryTests.testStats` — saves 3 completed rows then asserts totalCount=3, totalDurationMs=6000. Lifetime increments produce same values.
- `PrivateDictationTests.testStatsIncludeHiddenRows` — both visible and hidden contribute to lifetime; totals match.
- `RepositoryEdgeCaseTests` — same.

Run focused database tests during implementation, then full `swift test` before commit.

## Files Touched

- `Sources/MacParakeetCore/Database/DatabaseManager.swift` — add `v0.7.4-lifetime-dictation-stats` migration. Migration calls the shared `recomputeLifetimeStats()` helper for backfill (same code path as the rollback recipe).
- `Sources/MacParakeetCore/Database/DictationRepository.swift` — modify `save()` (transition + delta logic), modify `stats()` (read from new table), add private `incrementLifetimeStats(db:durationMs:wordCount:)` and `applyLifetimeDelta(db:durationDelta:wordDelta:newDurationMs:)` helpers, add internal `recomputeLifetimeStats(in:)` shared with migration, add `LifetimeStatsError` enum (`.singletonMissing`), update `DictationStats` doc comments to clarify lifetime vs. visible semantics.
- `Tests/MacParakeetTests/Database/LifetimeDictationStatsTests.swift` — new.
- `spec/01-data-model.md` — document the new table.
- `CLAUDE.md` — one-line note in Database section.

## Migration Risk

- Backfill runs the shared `recomputeLifetimeStats()` helper inside the migration's transaction. Pure SQL, no Swift loop. Safe on any DB size.
- Users on the *current* deflated state (e.g. the user from #124) will lock in their depleted totals. No way to recover historical loss; new dictations accrue normally going forward.
- Rollback / recovery recipe: call `recomputeLifetimeStats(db:)` (single source of truth, also called by the migration backfill). Uses `INSERT OR REPLACE` so it self-heals even if the singleton row was deleted:
  ```sql
  INSERT OR REPLACE INTO lifetime_dictation_stats
    (id, totalCount, totalDurationMs, totalWords, longestDurationMs, updatedAt)
  SELECT 1,
         COUNT(*),
         COALESCE(SUM(durationMs), 0),
         COALESCE(SUM(wordCount), 0),
         COALESCE(MAX(durationMs), 0),
         ?
  FROM dictations
  WHERE status = 'completed';
  ```

## What This Plan Does NOT Do

- Does not retroactively restore user data lost before this fix ships.
- Does not change the visible UI layout.
- Does not split lifetime / private counters.
- Does not change CLI command output (only field semantics, which the CLI labels as "Total: visible count" anyway).
- Does not introduce a "Reset all stats including lifetime" affordance. If users want true zeroing, they can delete the SQLite file. (We could add an explicit "Reset Lifetime Stats" button in Settings later — punt unless asked.)
