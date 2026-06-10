import Foundation

/// Serializes Transform runs so at most one run body executes at a time.
///
/// Re-triggering a Transform cancels the previous run *and* waits for it to
/// fully wind down before the next run's body starts. The wait matters:
/// `TransformExecutor` deliberately ignores cancellation once its replace
/// phase has begun (aborting between ⌘V and the clipboard restore would
/// leave the host app half-pasted), so for a short window after cancellation
/// the old run may still write the pasteboard, re-activate its target app,
/// and post ⌘V. Starting the next run's selection capture during that window
/// could capture the old run's payload off the pasteboard or read from the
/// wrong app. (AUDIT-072, `docs/audits/2026-06-09-codebase-audit.md`.)
@MainActor
public final class TransformRunSerializer {
    private var current: Task<Void, Never>?

    /// Bumped on every `replace(with:)` so a finished run only clears
    /// `current` if it hasn't already been superseded — the same generation
    /// idiom the audio/runtime layers use against stale fire-and-forget work.
    private var generation = 0

    public init() {}

    /// Cancel the in-flight run, if any, and start `body` once it has fully
    /// wound down. A body that is superseded again before the previous run
    /// finishes never starts at all.
    @discardableResult
    public func replace(with body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = current
        previous?.cancel()
        generation += 1
        let myGeneration = generation
        let task = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }
            if !Task.isCancelled {
                await body()
            }
            if let self, self.generation == myGeneration {
                self.current = nil
            }
        }
        current = task
        return task
    }

    /// Cancel the in-flight run without starting a new one. The cancelled
    /// body still winds down cooperatively on its own task, and `current`
    /// deliberately keeps referencing it: a `replace(with:)` that follows a
    /// `cancel()` must still wait for the cancelled run to wind down, or the
    /// AUDIT-072 overlap returns through the cancel-then-retrigger path.
    /// The finished task clears `current` itself via the generation guard.
    public func cancel() {
        current?.cancel()
    }
}
