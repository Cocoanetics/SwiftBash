// Embeddable demo: a Swift program that runs both bash and JS
// against a shared in-process environment. Neither touches the
// host process env — they communicate purely through the Shell's
// virtual environment dictionary.
//
//   swift Examples/shell-shared-env.swift
//
// Run from the SwiftJS package root.
import BashInterpreter
import BashCommandKit
import SwiftJSCore

@main
struct Demo {
    static func main() async throws {
        let shell = Shell()
        shell.registerStandardCommands()

        // Step 1: a bash script sets a variable in the shell.
        print("--- step 1: bash sets a var ---")
        try await shell.run("MY_TOKEN='from bash'; echo \"bash sees: $MY_TOKEN\"")

        // Step 2: hand the same shell's environment to a JSRuntime
        // and let JS read it.
        print("\n--- step 2: JS reads via ShellEnvProvider ---")
        let js = JSRuntime(envProvider: ShellEnvProvider(shell))
        js.run("""
        console.log("js sees:", process.env.MY_TOKEN);
        process.env.MY_TOKEN = 'rewritten by JS';
        process.env.JS_GIFT = 'hello from js';
        """)

        // Step 3: bash sees the JS mutations.
        print("\n--- step 3: bash sees the JS mutations ---")
        try await shell.run("""
            echo "MY_TOKEN now: $MY_TOKEN"
            echo "JS_GIFT now: $JS_GIFT"
            """)

        // Step 4: prove the host process is untouched.
        print("\n--- step 4: host process env untouched ---")
        let realToken = ProcessInfo.processInfo.environment["MY_TOKEN"] ?? "<unset>"
        print("ProcessInfo.processInfo.environment.MY_TOKEN = \(realToken)")
    }
}
