import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct PagerCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: - cat-fallback behaviour (no presenter, no TTY)

    @Test func lessNoPresenterCatsStdin() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\nb\\nc\\n' | less")
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func moreNoPresenterCatsStdin() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\nb\\nc\\n' | more")
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func lessNoPresenterReadsFile() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'hello\\n' > /tmp/less-fixture.txt")
        try await cap.shell.run("less /tmp/less-fixture.txt")
        #expect(cap.stdout.hasSuffix("hello\n"))
    }

    @Test func lessMissingFile() async throws {
        let cap = makeShell()
        try await cap.shell.run("less /tmp/does-not-exist-xyz.txt; echo done=$?")
        #expect(cap.stderr.contains("No such file or directory"))
        #expect(cap.stdout.contains("done=1"))
    }

    @Test func lessSqueezesMultiFileHeaders() async throws {
        // -s belongs to `more`; here we just verify multi-file headers.
        let cap = makeShell()
        try await cap.shell.run("printf 'A\\n' > /tmp/p1.txt")
        try await cap.shell.run("printf 'B\\n' > /tmp/p2.txt")
        try await cap.shell.run("less /tmp/p1.txt /tmp/p2.txt")
        #expect(cap.stdout.contains("/tmp/p1.txt"))
        #expect(cap.stdout.contains("/tmp/p2.txt"))
        #expect(cap.stdout.contains("A"))
        #expect(cap.stdout.contains("B"))
    }

    @Test func moreSqueezeFlagCollapsesBlanks() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\n\\n\\n\\nb\\n' | more -s")
        #expect(cap.stdout == "a\n\nb\n")
    }

    // MARK: - Argv parsing

    @Test func lessRejectsUnknownFlag() async throws {
        let cap = makeShell()
        try await cap.shell.run("less -Z; echo done=$?")
        #expect(cap.stderr.contains("unrecognized option"))
        #expect(cap.stdout.contains("done=2"))
    }

    @Test func lessAcceptsCommonFlags() async throws {
        let cap = makeShell()
        // -N, -i, -S, -R, -X, -F should all parse cleanly even in
        // cat-fallback mode.
        try await cap.shell.run("printf 'x\\n' | less -NiSRXF; echo done=$?")
        #expect(cap.stdout.contains("x\n"))
        #expect(cap.stdout.contains("done=0"))
    }

    @Test func lessHelpExitsZero() async throws {
        let cap = makeShell()
        try await cap.shell.run("less --help; echo done=$?")
        #expect(cap.stdout.contains("Usage: less"))
        #expect(cap.stdout.contains("done=0"))
    }

    @Test func lessLessEnvVarParsedAsShorthand() async throws {
        let cap = makeShell()
        // LESS=FRX means -F -R -X; in cat-fallback mode all are no-ops
        // but the parser must not reject them.
        try await cap.shell.run("LESS=FRX printf 'x\\n' | less; echo done=$?")
        #expect(cap.stdout.contains("x\n"))
        #expect(cap.stdout.contains("done=0"))
    }

    // MARK: - Presenter mode

    /// Records every pager request it sees and returns immediately.
    final class RecordingPresenter: InteractivePresenter, @unchecked Sendable {
        let lock = NSLock()
        private var _requests: [PagerRequest] = []
        var requests: [PagerRequest] {
            lock.withLock { _requests }
        }
        func presentPager(_ request: PagerRequest) async throws {
            lock.withLock { _requests.append(request) }
        }
    }

    @Test func lessPresenterReceivesContent() async throws {
        let cap = makeShell()
        let presenter = RecordingPresenter()
        cap.shell.interactivePresenter = presenter
        cap.shell.stdoutIsTTY = true
        try await cap.shell.run("printf 'one\\ntwo\\nthree\\n' | less")
        let reqs = presenter.requests
        try #require(reqs.count == 1)
        #expect(reqs[0].mode == .less)
        #expect(reqs[0].content == "one\ntwo\nthree\n")
        // Nothing should hit stdout in pager mode — the presenter
        // takes over rendering.
        #expect(cap.stdout.isEmpty)
    }

    @Test func morePresenterModeIsMore() async throws {
        let cap = makeShell()
        let presenter = RecordingPresenter()
        cap.shell.interactivePresenter = presenter
        cap.shell.stdoutIsTTY = true
        try await cap.shell.run("printf 'x\\n' | more")
        let reqs = presenter.requests
        try #require(reqs.count == 1)
        #expect(reqs[0].mode == .more)
    }

    @Test func lessForwardsRenderingFlags() async throws {
        let cap = makeShell()
        let presenter = RecordingPresenter()
        cap.shell.interactivePresenter = presenter
        cap.shell.stdoutIsTTY = true
        // Make sure the content is too long to fit in one screen so -F
        // doesn't bypass the presenter.
        let bigBody = (1...200).map(String.init).joined(separator: "\\n")
        try await cap.shell.run("printf '\(bigBody)\\n' | less -NiS +G")
        let reqs = presenter.requests
        try #require(reqs.count == 1)
        #expect(reqs[0].lineNumbers == true)
        #expect(reqs[0].ignoreCaseInSearch == true)
        #expect(reqs[0].chopLongLines == true)
        #expect(reqs[0].startAtEnd == true)
    }

    @Test func lessQuitIfOneScreenBypassesPager() async throws {
        let cap = makeShell()
        let presenter = RecordingPresenter()
        cap.shell.interactivePresenter = presenter
        cap.shell.stdoutIsTTY = true
        // Three lines, default LINES=24 → fits → cat path.
        try await cap.shell.run("printf 'a\\nb\\nc\\n' | less -F")
        let reqs = presenter.requests
        #expect(reqs.isEmpty)
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func lessQuitIfOneScreenStillPagesLongContent() async throws {
        let cap = makeShell()
        let presenter = RecordingPresenter()
        cap.shell.interactivePresenter = presenter
        cap.shell.stdoutIsTTY = true
        // 100 lines, LINES=24 → too tall → pager.
        var body = ""
        for n in 1...100 { body += "line \(n)\\n" }
        try await cap.shell.run("printf '\(body)' | less -F")
        let reqs = presenter.requests
        #expect(reqs.count == 1)
    }

    @Test func lessMissingFilenameInPagerMode() async throws {
        let cap = makeShell()
        let presenter = RecordingPresenter()
        cap.shell.interactivePresenter = presenter
        cap.shell.stdoutIsTTY = true
        try await cap.shell.run("less </dev/null; echo done=$?")
        #expect(cap.stderr.contains("missing filename"))
        #expect(cap.stdout.contains("done=1"))
    }

    // MARK: - Pipeline TTY propagation

    @Test func lessInPipelineMiddleActsAsCat() async throws {
        let cap = makeShell()
        let presenter = RecordingPresenter()
        cap.shell.interactivePresenter = presenter
        cap.shell.stdoutIsTTY = true
        // `less` in the middle: its stdout is a pipe, so stdoutIsTTY
        // should be false for that stage even though the outer shell
        // is interactive. Expected: less behaves as cat.
        try await cap.shell.run("printf 'hi\\n' | less | tr h H")
        let reqs = presenter.requests
        #expect(reqs.isEmpty)
        #expect(cap.stdout == "Hi\n")
    }
}
