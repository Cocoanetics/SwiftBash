import Testing
@testable import BashInterpreter
@testable import BashCommandKit

/// `${1:-default}` and friends previously routed through `environment[name]`
/// rather than `lookup`, so positional parameters were invisible to the
/// `:-` / `:=` / `:?` / `:+` forms. Pin the behaviour now that they read
/// through `lookupOptional`.
@Suite("Positional parameters in :-/:=/:?/:+")
struct PositionalParamDefaultExpansionTests {

    private func makeShellWithArgs(_ args: [String]) -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.positionalParameters = args
        return cap
    }

    @Test("`${1:-fallback}` returns $1 when $1 is set")
    func defaultWithSetParam() async throws {
        let cap = makeShellWithArgs(["foo", "bar"])
        let status = try await cap.shell.run(#"echo "${1:-fallback}""#)
        #expect(status == .success)
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "foo")
    }

    @Test("`${1:-fallback}` returns the fallback when $1 is unset")
    func defaultWithUnsetParam() async throws {
        let cap = makeShellWithArgs([])
        let status = try await cap.shell.run(#"echo "${1:-fallback}""#)
        #expect(status == .success)
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "fallback")
    }

    @Test("`${1:?msg}` succeeds when $1 is set")
    func errorIfUnsetWithSetParam() async throws {
        let cap = makeShellWithArgs(["foo"])
        let status = try await cap.shell.run(#"echo "${1:?need an arg}""#)
        #expect(status == .success)
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "foo")
        #expect(cap.stderr.isEmpty)
    }

    @Test("`${1:?msg}` errors when $1 is unset")
    func errorIfUnsetWithUnsetParam() async throws {
        let cap = makeShellWithArgs([])
        let status = try await cap.shell.run(#"echo "${1:?usage: thing FILE}""#)
        #expect(!status.isSuccess)
        #expect(cap.stderr.contains("usage: thing FILE"))
    }

    @Test("`${1:+alt}` returns alt when $1 is set")
    func alternativeWithSetParam() async throws {
        let cap = makeShellWithArgs(["foo"])
        let status = try await cap.shell.run(#"echo "${1:+have-arg}""#)
        #expect(status == .success)
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "have-arg")
    }

    @Test("`${1:+alt}` returns empty when $1 is unset")
    func alternativeWithUnsetParam() async throws {
        let cap = makeShellWithArgs([])
        let status = try await cap.shell.run(#"echo "${1:+have-arg}""#)
        #expect(status == .success)
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "")
    }

    @Test("`${1:=default}` returns the default when $1 is unset")
    func assignDefault() async throws {
        // `:=` on a positional parameter is a syntax error in real
        // bash, but iBash currently treats it like `:-` for positional
        // params. Pin that "as if :-" behaviour for now so a future
        // tighter check is intentional.
        let cap = makeShellWithArgs([])
        let status = try await cap.shell.run(#"echo "${1:=fallback}""#)
        #expect(status == .success)
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "fallback")
    }

    @Test("$# and $@ keep working alongside the new lookup")
    func countAndAllStillWork() async throws {
        let cap = makeShellWithArgs(["foo", "bar", "baz"])
        let status = try await cap.shell.run(#"echo "$# $@""#)
        #expect(status == .success)
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "3 foo bar baz")
    }
}
