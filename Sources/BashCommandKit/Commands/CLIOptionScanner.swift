import Foundation

/// Tiny helper for hand-rolled option parsing in commands that take
/// `captureForPassthrough` argv.
///
/// SwiftBash's `ParsableBashCommand` bridge runs ArgumentParser in a
/// mode that does **not** accept value-bearing short options in their
/// attached form (`-g1`, `-N64`, `-tx1`) — only the separated `-g 1`.
/// GNU/BSD users routinely write the attached form, so commands that
/// want to honour it scan their own argv with this helper instead.
enum CLIOptionScanner {

    /// Match a value-bearing option at `argv[index]` in either the
    /// attached (`-gN`, `--long=N`) or separated (`-g N`, `--long N`)
    /// form.
    ///
    /// - Returns: the option's value and how many argv slots it
    ///   consumed (1 for an attached form, 2 for a separated one), or
    ///   `nil` if `argv[index]` is not this option.
    static func value(_ arg: String, short: Character, long: String,
                      argv: [String], at index: Int)
        -> (value: String, advance: Int)? {
        let shortFlag = "-\(short)"
        let longFlag = "--\(long)"
        // Separated: `-g 1` / `--groupsize 1`.
        if arg == shortFlag || arg == longFlag {
            guard index + 1 < argv.count else { return nil }
            return (argv[index + 1], 2)
        }
        // Attached short: `-g1`.
        if arg.hasPrefix(shortFlag), arg.count > shortFlag.count {
            return (String(arg.dropFirst(shortFlag.count)), 1)
        }
        // Attached long: `--groupsize=1`.
        if arg.hasPrefix(longFlag + "=") {
            return (String(arg.dropFirst(longFlag.count + 1)), 1)
        }
        return nil
    }
}
