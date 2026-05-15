#if !os(Windows)

import Foundation

// MARK: - Exception formatting
//
// Surface uncaught exceptions in a Node-ish shape:
//
//     <sourceURL>:<line>
//     <source line>
//         ^
//
//     <ErrorName>: <message>
//         <stack...>
//
// The code-frame is only produced when we can resolve the
// sourceURL to a real on-disk file — for `-e` snippets we fall
// back to message + stack. Split out of `JSRuntime.swift` to keep
// that file below the file_length limit.

extension JSRuntime {

    func formatException(_ exception: JSValue) -> String {
        let message = exception.toString() ?? "<unknown>"
        let stack = nonEmpty(exception, "stack")

        let sourceURL = nonEmpty(exception, "sourceURL")
        let line = exception.objectForKeyedSubscript("line")?.toInt32() ?? 0
        let column = exception.objectForKeyedSubscript("column")?.toInt32() ?? 0

        var out = ""
        if let frame = codeFrame(sourceURL: sourceURL, line: line, column: column) {
            out += frame + "\n\n"
        }
        out += message + "\n"
        if let stack { out += stack + "\n" }
        return out
    }

    func nonEmpty(_ value: JSValue, _ key: String) -> String? {
        guard let prop = value.objectForKeyedSubscript(key),
              !prop.isUndefined, !prop.isNull,
              let str = prop.toString(), !str.isEmpty else { return nil }
        return str
    }

    /// Read `sourceURL`'s line `line` and produce a Node-style
    /// `path:line\n  source\n  ^` frame. Returns nil when the file
    /// can't be read (e.g. `[eval]` pseudo-paths).
    func codeFrame(sourceURL: String?, line: Int32, column: Int32) -> String? {
        guard let sourceURL, line > 0 else { return nil }
        let path: String
        if sourceURL.hasPrefix("file://"), let url = URL(string: sourceURL) {
            path = url.path
        } else {
            path = sourceURL
        }
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let lines = source.split(omittingEmptySubsequences: false,
                                  whereSeparator: { $0 == "\n" })
        let idx = Int(line) - 1
        guard idx >= 0, idx < lines.count else { return nil }
        let lineText = String(lines[idx])
        var frame = "\(path):\(line)\n\(lineText)"
        // Required modules are wrapped in a CommonJS factory whose
        // prefix lives on the same line as the user's first line, so
        // the column on line 1 is shifted by the prefix length. We
        // can't recover the original column without tracking the
        // offset, so suppress the caret when it would point past the
        // visible source line — better no caret than a misleading one.
        if column > 0, Int(column) <= lineText.count + 1 {
            // JSC columns are 1-based for the visible character.
            let caret = String(repeating: " ", count: max(0, Int(column) - 1)) + "^"
            frame += "\n" + caret
        }
        return frame
    }
}

#endif  // !os(Windows)
