import Foundation

extension Shell {

    // Second half of argv expansion: take fragments from
    // ``collectArgFragments(word:)`` and apply field splitting using
    // the *current* `$IFS`. Renamed from the old internal helper so
    // the executor can call it after applying prefix assignments.
    //
    // Dispatches over the four ``WordFragment`` cases; per-case helpers
    // would scatter the merge-into-current vs. start-new-arg logic.
    // swiftlint:disable:next cyclomatic_complexity
    func assembleArgs(_ fragments: [WordFragment]) -> [String] {
        var args: [String] = []
        var current = ""
        // True once any fragment has contributed to `current` — even if
        // that contribution was the empty string (from `""` or `''`).
        // Distinguishes `cmd ""` (1 arg, "") from `cmd $UNSET` (0 args).
        var currentLive = false

        for frag in fragments {
            switch frag {
            case .literal(let text):
                current += text
                currentLive = true

            case .unquotedSub(let text):
                let pieces = ifsSplit(text)
                if pieces.isEmpty { continue }
                appendPiecesAsArgs(pieces,
                                   current: &current,
                                   currentLive: &currentLive,
                                   args: &args)

            case .dollarAtQuoted(let values):
                if values.isEmpty { continue }
                appendPiecesAsArgs(values,
                                   current: &current,
                                   currentLive: &currentLive,
                                   args: &args)

            case .dollarAtUnquoted(let values):
                if values.isEmpty { continue }
                var pieces: [String] = []
                for value in values {
                    pieces.append(contentsOf: ifsSplit(value))
                }
                if pieces.isEmpty { continue }
                appendPiecesAsArgs(pieces,
                                   current: &current,
                                   currentLive: &currentLive,
                                   args: &args)
            }
        }

        if currentLive { args.append(current) }
        return args
    }

    private func appendPiecesAsArgs(
        _ pieces: [String],
        current: inout String,
        currentLive: inout Bool,
        args: inout [String]
    ) {
        for (idx, piece) in pieces.enumerated() {
            if idx == 0 {
                current += piece
            } else {
                args.append(current)
                current = piece
            }
            currentLive = true
        }
    }
}
