import ArgumentParser
import BashSyntax
import Foundation

/// `swift-bash parse` — parse a bash command or file and print the AST.
struct ParseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parse",
        abstract: "Parse a bash command or file and print its AST."
    )

    @Argument(help: "The bash source to parse. Omit if --file is given.")
    var source: String?

    @Option(name: [.short, .long],
            help: "Path to a bash script to read instead of parsing inline source.")
    var file: String?

    @Flag(name: [.customShort("s"), .long],
          help: "Show source slices instead of character positions.")
    var withSource: Bool = false

    @Flag(help: "Only parse the first top-level unit.")
    var first: Bool = false

    func validate() throws {
        if source == nil, file == nil {
            throw ValidationError("Provide either a source argument or --file.")
        }
        if source != nil, file != nil {
            throw ValidationError("Specify either a source argument or --file, not both.")
        }
    }

    func run() throws {
        let src: String
        if let source {
            src = source
        } else if let file {
            do {
                src = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                throw CLIError("could not read \(file): \(error.localizedDescription)")
            }
        } else {
            // validate() guarantees this is unreachable.
            throw ValidationError("Provide either a source argument or --file.")
        }

        let dumpSource = withSource ? src : nil

        do {
            let parts = first
                ? [try BashSyntax.parseSingle(src)]
                : try BashSyntax.parse(src)
            for part in parts {
                print(part.dump(source: dumpSource))
            }
        } catch let err as BashSyntaxError {
            throw CLIError(err.description)
        }
    }
}
