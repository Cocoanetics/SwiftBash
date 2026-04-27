import Foundation

/// In-memory virtual process table. Each `Shell` has one; backgrounded
/// commands (`cmd &`) and any other "spawn-like" operation register a
/// virtual PID here, with the underlying Swift `Task` retained so the
/// shell can `wait` on it or signal it.
///
/// **Crucially virtual.** PIDs are monotonic counters allocated by this
/// table — they do *not* correspond to host process IDs and the table
/// only knows about Tasks SwiftBash itself spawned. `ps` / `kill` /
/// `pgrep` / `pkill` operate on these entries; there is no path from
/// here to the real OS process table.
///
/// **Cancellation is cooperative.** `signal(_:)` calls `Task.cancel()`
/// on the entry's Task. The Task body must observe `Task.isCancelled`
/// (or be `await`-ing a cancellable primitive) to actually stop —
/// Swift Concurrency does not preempt CPU-bound code. That's the same
/// limitation as `kill -TERM` against a process ignoring SIGTERM.
public actor ProcessTable {

    /// One entry. Created when something spawns; promoted to `.exited`
    /// or `.failed` when the Task completes; never removed (so `$!`
    /// references survive after the Task is done, matching bash).
    public struct Entry: Sendable {
        public enum State: Sendable, Equatable {
            case running
            case exited(ExitStatus)
            case failed(message: String)
            case cancelled
        }
        public let pid: Int32
        public let command: String
        public let startedAt: Date
        public var state: State
    }

    private var nextPID: Int32
    private var entries: [Int32: Entry] = [:]
    /// Internal Tasks store the outcome (status + state) directly so
    /// errors never need to escape the Task boundary.
    private var tasks: [Int32: Task<TaskOutcome, Never>] = [:]
    /// Most-recently-spawned PID — what `$!` resolves to.
    public private(set) var lastBackgroundPID: Int32? = nil

    public init(startingAt: Int32 = 1000) {
        self.nextPID = startingAt
    }

    /// Allocate a fresh virtual PID, register an `Entry`, and run
    /// `body` in a detached `Task`. The returned Task is retained by
    /// the table; `wait(pid:)` awaits it, `signal(pid:_:)` cancels it.
    ///
    /// `body` should run the command in its own subshell — use
    /// `Shell.current.copy()` then `withCurrent { … }` so the spawned
    /// Task has the right shell. The factory closure assembles that
    /// before this call.
    public func spawn(
        command: String,
        body: @Sendable @escaping () async throws -> ExitStatus
    ) -> Int32 {
        let pid = nextPID
        nextPID += 1
        entries[pid] = Entry(pid: pid, command: command,
                             startedAt: Date(), state: .running)
        // Wrap the body in an internal `Task<…, Never>` so errors
        // never escape. If a thrown error reached the unstructured
        // Task's value, Swift's runtime would log it to stderr as a
        // stray "Error: CancellationError()". Bottling the result as
        // a (status, state) pair keeps that quiet.
        let task = Task<TaskOutcome, Never> {
            do {
                let s = try await body()
                return TaskOutcome(status: s, state: .exited(s))
            } catch is CancellationError {
                return TaskOutcome(status: ExitStatus(143), state: .cancelled)
            } catch {
                return TaskOutcome(
                    status: ExitStatus(1),
                    state: .failed(message: String(describing: error)))
            }
        }
        tasks[pid] = task
        lastBackgroundPID = pid
        // Completion observer — flips entry state when the Task ends
        // so `ps` reports "exited" / "cancelled" without needing
        // `wait`.
        Task { [weak self] in
            let outcome = await task.value
            await self?.markFinished(pid: pid, state: outcome.state)
        }
        return pid
    }

    private struct TaskOutcome: Sendable {
        let status: ExitStatus
        let state: Entry.State
    }

    /// Await the Task at `pid`; returns its exit status, or the status
    /// of an entry that has already finished. Returns `nil` if `pid`
    /// is unknown.
    public func wait(pid: Int32) async -> ExitStatus? {
        if let entry = entries[pid] {
            switch entry.state {
            case .exited(let s): return s
            case .failed: return ExitStatus(1)
            case .cancelled: return ExitStatus(143) // 128 + SIGTERM
            case .running: break // fall through and await
            }
        }
        guard let task = tasks[pid] else { return nil }
        return await task.value.status
    }

    /// Wait for every still-running entry. Returns the LAST awaited
    /// status — bash's `wait` (no args) returns 0 if there were no
    /// jobs, else the last job's status.
    public func waitAll() async -> ExitStatus {
        let pending = entries.compactMap {
            $0.value.state == .running ? $0.key : nil
        }.sorted()
        var last = ExitStatus.success
        for pid in pending {
            if let s = await wait(pid: pid) { last = s }
        }
        return last
    }

    /// Cancel the Task at `pid`. Cooperative — the Task must observe
    /// cancellation. Returns `true` if the entry exists, regardless of
    /// whether the Task actually noticed.
    public func signal(pid: Int32, signo: Int32 = 15 /*SIGTERM*/) -> Bool {
        guard let task = tasks[pid] else { return false }
        task.cancel()
        return true
    }

    /// All entries, sorted by PID. Used by `ps`, `pgrep`, `jobs`.
    public func list() -> [Entry] {
        return entries.values.sorted { $0.pid < $1.pid }
    }

    /// Look up by PID. Used by `kill PID` to validate before signal.
    public func entry(for pid: Int32) -> Entry? {
        return entries[pid]
    }

    private func markFinished(pid: Int32, state: Entry.State) {
        if var e = entries[pid] {
            // Don't overwrite a state we set deliberately (e.g. a
            // signal landing right at the same moment as natural exit).
            if case .running = e.state {
                e.state = state
                entries[pid] = e
            }
        }
        // Drop the strong Task reference now that it's done.
        tasks.removeValue(forKey: pid)
    }
}
