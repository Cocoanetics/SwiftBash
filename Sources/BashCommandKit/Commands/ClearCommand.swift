import ArgumentParser
import BashInterpreter

/// `clear` — emit the ANSI sequence that clears the visible screen
/// (`ESC [ 2J`) and homes the cursor (`ESC [ H`).
///
/// On a real terminal this scrolls the prior output above the visible
/// region rather than truly erasing the scrollback. Off a terminal
/// (piped, captured) the bytes still flow — useful for tests.
public struct ClearCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear the terminal screen."
    )

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        Shell.current.stdout("\u{1B}[2J\u{1B}[H")
        return .success
    }
}
