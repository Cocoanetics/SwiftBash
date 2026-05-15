import Foundation

// Hunk application routines for `patch`. Split out from
// `PatchCommand.swift` to keep the type body within size limits.

extension PatchCommand {

    func apply(hunks: [Hunk], to original: [String], reverse: Bool) throws -> [String] {
        // Apply hunks in source order, building output with offset
        // tracking so subsequent hunk indices stay correct.
        var out = original
        // Offset between original index and output index (for adjusting
        // later hunk start positions after earlier hunks change line
        // counts).
        var offset = 0
        for hunk in hunks {
            let oriented = reverse ? reversedHunk(hunk) : hunk
            let idx = oriented.oldStart - 1 + offset
            // Sanity-check: the lines we expect to remove or pass
            // through should match the file at this position.
            var contextChecked = 0
            var consumed = 0
            var produced: [String] = []
            for line in oriented.lines {
                guard let kind = line.first else { continue }
                let body = String(line.dropFirst())
                switch kind {
                case " ":
                    // Context: must match.
                    guard idx + contextChecked < out.count,
                          out[idx + contextChecked] == body else {
                        throw PatchError("hunk failed at line \(idx + contextChecked + 1)")
                    }
                    produced.append(body)
                    contextChecked += 1
                    consumed += 1
                case "-":
                    // Must match original.
                    guard idx + contextChecked < out.count,
                          out[idx + contextChecked] == body else {
                        throw PatchError("hunk failed at line \(idx + contextChecked + 1)")
                    }
                    contextChecked += 1
                    consumed += 1
                case "+":
                    produced.append(body)
                default:
                    // Skip pseudo-lines like "\ No newline at end of file".
                    continue
                }
            }
            // Replace the range [idx ..< idx + consumed] with produced.
            let endIdx = min(idx + consumed, out.count)
            out.replaceSubrange(idx..<endIdx, with: produced)
            offset += produced.count - consumed
        }
        return out
    }

    func reversedHunk(_ hunk: Hunk) -> Hunk {
        var swapped: [String] = []
        for line in hunk.lines {
            guard let first = line.first else { continue }
            let body = line.dropFirst()
            switch first {
            case "+": swapped.append("-" + body)
            case "-": swapped.append("+" + body)
            default:  swapped.append(line)
            }
        }
        return Hunk(oldStart: hunk.newStart, oldCount: hunk.newCount,
                    newStart: hunk.oldStart, newCount: hunk.oldCount,
                    lines: swapped,
                    sourceHeader: hunk.targetHeader, targetHeader: hunk.sourceHeader)
    }
}
