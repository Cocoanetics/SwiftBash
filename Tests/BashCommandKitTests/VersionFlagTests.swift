import Testing
@testable import BashInterpreter
@testable import BashCommandKit

/// `<tool> --version` should exit 0 and print a one-line identifier on
/// stdout for every builtin in the catalog. Covers the
/// `ParsableCommandBridge` short-circuit and the per-command fallbacks
/// in the few raw `Command` types (`find`, `time`, `timeout`). Tracks
/// the convention asked for in issue #36.
@Suite(.timeLimit(.minutes(1))) struct VersionFlagTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    /// The non-`ParsableBashCommand` builtins each grew an explicit
    /// short-circuit; assert they all respond.
    @Test(arguments: ["find", "time", "timeout"])
    func rawCommandTypesPrintVersion(_ tool: String) async throws {
        let cap = makeShell()
        // Bypass the bash parser — `time` is a reserved keyword that
        // the tokenizer routes to pipeline-timing semantics rather
        // than dispatching as a builtin. Going through the command
        // table directly exercises the same code path as a quoted
        // `\time --version`.
        let command = try #require(cap.shell.commands[tool])
        let status = try await Shell.$bashCurrent.withValue(cap.shell) {
            try await command.run([tool, "--version"])
        }
        #expect(status == .success)
        #expect(cap.stdout.contains(tool))
        #expect(cap.stdout.contains("SwiftBash"))
        #expect(cap.stderr.isEmpty)
    }

    /// `--version` in a child-command's argv must pass through —
    /// `time` / `timeout` are wrappers, and consuming `--version` at
    /// the wrapper level would skip the wrapped command entirely.
    @Test func timeoutForwardsVersionToWrappedCommand() async throws {
        let cap = makeShell()
        try await cap.shell.run("timeout 5 cat --version")
        // cat's banner, not timeout's.
        #expect(cap.stdout.contains("cat (SwiftBash)"))
        #expect(!cap.stdout.contains("timeout (SwiftBash)"))
    }

    /// `find` expressions can contain literal `--version` tokens
    /// (e.g. `-name --version`). The version guard must not swallow
    /// them.
    @Test func findExpressionWithVersionTokenIsNotIntercepted() async throws {
        let cap = makeShell()
        // Pointed at an empty path so the walker has no matches —
        // we only care that `find` runs the expression instead of
        // printing the version banner.
        try await cap.shell.run("find /nonexistent-path-zzz -name --version; echo done=$?")
        #expect(!cap.stdout.contains("find (SwiftBash)"))
        #expect(cap.stdout.contains("done="))
    }

    /// Spot-check a handful of bridge-routed builtins from the parsers
    /// the issue explicitly called out — they should pick up the
    /// banner from `ParsableCommandBridge` without per-command work.
    @Test(arguments: ["cat", "grep", "sed", "curl", "xargs", "ls"])
    func bridgeCommandsPrintVersion(_ tool: String) async throws {
        let cap = makeShell()
        try await cap.shell.run("\(tool) --version")
        #expect(cap.stdout.contains("SwiftBash"))
        #expect(cap.stderr.isEmpty)
    }
}
