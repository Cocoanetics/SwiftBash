import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Coverage for `[ -t N ]` / `test -t N`. The per-fd `*IsTTY`
/// flags on `Shell` are the source of truth; pipelines flip the
/// matching flag off on stages whose fd is a pipe.
@Suite(.timeLimit(.minutes(1))) struct TestDashTTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: - Per-fd flags

    @Test func dashTOneReadsStdoutFlag() async throws {
        let cap = makeShell()
        cap.shell.stdoutIsTTY = true
        try await cap.shell.run("[ -t 1 ] && echo tty || echo notty")
        #expect(cap.stdout == "tty\n")
    }

    @Test func dashTOneFalseByDefault() async throws {
        let cap = makeShell()
        // Default: no TTY flags set — `CapturingShell` is a batch
        // sink, not an interactive surface.
        try await cap.shell.run("[ -t 1 ] && echo tty || echo notty")
        #expect(cap.stdout == "notty\n")
    }

    @Test func dashTZeroReadsStdinFlag() async throws {
        let cap = makeShell()
        cap.shell.stdinIsTTY = true
        try await cap.shell.run("[ -t 0 ] && echo tty || echo notty")
        #expect(cap.stdout == "tty\n")
    }

    @Test func dashTTwoReadsStderrFlag() async throws {
        let cap = makeShell()
        cap.shell.stderrIsTTY = true
        try await cap.shell.run("[ -t 2 ] && echo tty || echo notty")
        #expect(cap.stdout == "tty\n")
    }

    @Test func dashTUnknownFdReturnsFalse() async throws {
        let cap = makeShell()
        cap.shell.stdoutIsTTY = true
        try await cap.shell.run("[ -t 7 ] && echo tty || echo notty")
        #expect(cap.stdout == "notty\n")
    }

    // MARK: - Pipelines flip flags off for the piped fd

    @Test func stdoutFlagOffInsidePipeProducer() async throws {
        let cap = makeShell()
        cap.shell.stdoutIsTTY = true
        // Producer's stdout writes to the pipe — must NOT report as
        // a tty even though the outer shell is interactive.
        try await cap.shell.run(
            "([ -t 1 ] && echo tty || echo notty) | cat")
        #expect(cap.stdout == "notty\n")
    }

    @Test func stdinFlagOffInsidePipeConsumer() async throws {
        let cap = makeShell()
        cap.shell.stdinIsTTY = true
        cap.shell.stdoutIsTTY = true
        // Consumer's stdin reads from the pipe — must NOT report as
        // a tty.
        try await cap.shell.run(
            "echo upstream | ([ -t 0 ] && echo tty || echo notty)")
        #expect(cap.stdout.contains("notty"))
    }

    @Test func stdoutFlagStillOnForLastStage() async throws {
        let cap = makeShell()
        cap.shell.stdoutIsTTY = true
        // The TAIL of a pipeline writes to outer stdout — TTY flag
        // is inherited.
        try await cap.shell.run(
            "echo upstream | ([ -t 1 ] && echo tty || echo notty)")
        #expect(cap.stdout.contains("tty"))
    }

    // MARK: - Real-world idiom from the colourful-hello-world script

    @Test func colourGatingIdiomEmitsEscapes() async throws {
        let cap = makeShell()
        cap.shell.stdoutIsTTY = true
        try await cap.shell.run(#"""
            if [ -t 1 ]; then esc=$'\033'; else esc=''; fi
            red="${esc}[31m"
            reset="${esc}[0m"
            printf '%shi%s\n' "$red" "$reset"
        """#)
        // ANSI prefix + payload + reset = `\e[31mhi\e[0m\n`. The
        // important assertion is that the ESC byte is present —
        // without `-t 1` being honoured, the escapes would be empty
        // strings and the output would just be `hi\n`.
        #expect(cap.stdout.contains("\u{1B}[31m"))
        #expect(cap.stdout.contains("\u{1B}[0m"))
    }
}
