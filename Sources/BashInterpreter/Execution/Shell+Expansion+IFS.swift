import Foundation

extension Shell {

    // Split `s` on the active `$IFS` value, following bash's two-tier
    // rule:
    //
    // - **Whitespace IFS chars** (`space`, `tab`, `newline` — by
    //   default *all* of `$IFS`): runs of them collapse to a single
    //   delimiter; leading/trailing runs produce no empty fields.
    // - **Non-whitespace IFS chars** (e.g. `:` when `IFS=":"`): each
    //   one is a *hard* delimiter that *does* produce an empty field
    //   if there's nothing to its left, and it absorbs adjacent
    //   whitespace IFS chars.
    //
    // Special cases:
    // - `IFS` unset → default `" \t\n"`.
    // - `IFS` set to empty string → no splitting (returns `[s]`).
    // - Empty input → `[]`.
    //
    // POSIX two-tier delimiter dispatch (whitespace vs hard IFS chars)
    // is a tightly-coupled scan; pulling out the per-run handler would
    // hide the field-emission rule that's the whole point of the loop.
    // swiftlint:disable:next cyclomatic_complexity
    func ifsSplit(_ source: String) -> [String] {
        guard let ifs = environment["IFS"] else {
            return defaultWhitespaceSplit(source)
        }
        if ifs.isEmpty { return [source] }
        if source.isEmpty { return [] }

        let defaultWhitespace: Set<Character> = [" ", "\t", "\n"]
        let ifsChars = Set(ifs)
        let ifsWhitespace = ifsChars.intersection(defaultWhitespace)
        let ifsHard = ifsChars.subtracting(defaultWhitespace)

        // Pure-whitespace IFS: just collapse runs and trim edges.
        if ifsHard.isEmpty {
            return source.split(whereSeparator: { ifsWhitespace.contains($0) })
                    .map(String.init)
        }

        // Each delimiter *run* (a maximal block of IFS chars) ends one
        // field and contributes some number of empty fields:
        // - hardCount = 0 (run is pure whitespace) → emit the field
        //   only if non-empty; no empties.
        // - hardCount > 0 → emit the field unconditionally, then
        //   `hardCount - 1` extra empty fields.
        //
        // This is what makes "a : b" yield ["a", "b"] (one delimiter
        // total — surrounding whitespace is absorbed by the colon)
        // while "a::b" yields ["a", "", "b"] (two delimiters → empty
        // between them) and "a:" yields just ["a"] (trailing single
        // hard doesn't add an empty after the last field).
        var fields: [String] = []
        var current = ""
        var index = source.startIndex

        while index < source.endIndex {
            let char = source[index]
            if !ifsChars.contains(char) {
                current.append(char)
                index = source.index(after: index)
                continue
            }
            // Start of a delimiter run.
            var hardCount = 0
            while index < source.endIndex, ifsChars.contains(source[index]) {
                if ifsHard.contains(source[index]) { hardCount += 1 }
                index = source.index(after: index)
            }
            if hardCount == 0 {
                if !current.isEmpty {
                    fields.append(current)
                    current = ""
                }
            } else {
                fields.append(current)
                current = ""
                for _ in 1..<hardCount {
                    fields.append("")
                }
            }
        }
        if !current.isEmpty {
            fields.append(current)
        }
        return fields
    }

    private func defaultWhitespaceSplit(_ source: String) -> [String] {
        let whitespace: Set<Character> = [" ", "\t", "\n"]
        return source.split(whereSeparator: { whitespace.contains($0) }).map(String.init)
    }

    /// First char of `$IFS` (unset ⇒ `" "`, empty ⇒ `""`). Used to
    /// join `$*` / `"$*"`.
    func dollarStarSeparator() -> String {
        guard let ifs = environment["IFS"] else { return " " }
        if ifs.isEmpty { return "" }
        return String(ifs.first!)
    }

    /// Split `arr[sub]` into `("arr", "sub")`. Only matches when the
    /// part before `[` is a valid identifier — so `${#arr[@]}` (which
    /// has body `#arr[@]`) doesn't get misclassified here and stays
    /// on the slow path through ``resolveParameter``.
    func arraySubscript(of body: String) -> (String, String)? {
        guard let leftBracket = body.firstIndex(of: "["), body.last == "]" else {
            return nil
        }
        let head = String(body[..<leftBracket])
        guard let first = head.first,
              first.isLetter || first == "_",
              head.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        let after = body.index(after: leftBracket)
        let last = body.index(before: body.endIndex)
        guard after <= last else { return nil }
        let sub = String(body[after..<last])
        return (head, sub)
    }
}
