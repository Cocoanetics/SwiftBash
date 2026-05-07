import Foundation

/// Static rewrite from ES module syntax to CommonJS.
///
/// JSC's public Swift/Obj-C API exposes only `evaluateScript` (script
/// mode); the `JSScript` class with `SourceType.module` is forward-
/// declared but not shipped in the SDK headers. So this experiment
/// approaches ESM the way Babel's `transform-modules-commonjs`
/// plugin does: rewrite the source before it hits JSC.
///
/// Coverage targets the common forms a person actually writes:
///
///     import { a, b }     from "./x"
///     import { a as b }   from "./x"
///     import x            from "./x"        // default
///     import * as ns      from "./x"
///     import x, { y, z }  from "./x"
///     import "./side-effect"
///     import("./dyn")     // dynamic
///     import.meta.url
///
///     export const x = 1
///     export let / var
///     export function foo() {}
///     export class Foo {}
///     export default expr
///     export { a, b as c }
///
/// What we deliberately don't handle:
///   - Top-level `await`. Script mode forbids it; would need full
///     module support which JSC doesn't expose.
///   - `export * from "./x"` (re-exports). Niche; skip.
///   - `import './x' assert { type: 'json' }`. Skip.
///   - Multi-line bodies of `import { ... }` are supported, but
///     anything else multi-line falls back to whatever JSC says.
///
/// This is a regex pass, not a parser. It is wrong on adversarial
/// input (the literal string `"export default 1"` in a JS string
/// literal will get rewritten). The cost of doing it properly is
/// pulling in a JS parser — out of scope.
public enum ESMRewriter {

    /// Rewrite `source` to CommonJS. If the source contains no ESM
    /// syntax, returns it unchanged so we don't disturb working
    /// code.
    public static func rewrite(_ source: String) -> String {
        // Cheap probe — skip the work if neither keyword is present.
        guard source.range(of: #"\b(import|export)\b"#, options: .regularExpression) != nil else {
            return source
        }

        // Pre-pass: convert aliased import lists in-place so that
        // when the generic regex rules below copy them into
        // destructuring patterns, JS parses them correctly.
        // `import { a as b }` →  ESM destructuring `{ a as b }` is
        // INVALID; the equivalent is `{ a: b }`.
        var src = normalizeAliasedImportLists(source)

        for (pattern, replacement, options) in rules {
            src = regexReplace(in: src, pattern: pattern, with: replacement, options: options)
        }
        // Final pass: expand the named-export markers we left for
        // `export { a, b as c }` etc.
        src = expandNamedExports(src)
        return src
    }

    /// Inside `import { ... } from "..."` lines, rewrite each
    /// `name as alias` to `name: alias` so when the generic regex
    /// emits `const { ... } = require(...)`, the destructuring is
    /// valid JS. Multi-line braces are supported.
    private static func normalizeAliasedImportLists(_ src: String) -> String {
        let pattern = #"(?m)(^[ \t]*import\s*(?:[A-Za-z_$][\w$]*\s*,\s*)?\{)([\s\S]+?)(\}\s+from\s+['"][^'"]+['"]\s*;?)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return src }
        let ns = src as NSString
        var out = ""
        var cursor = 0
        re.enumerateMatches(in: src, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let head = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            let tail = ns.substring(with: m.range(at: 3))
            // Within the brace body, `\b(\w+)\s+as\s+(\w+)\b` → `$1: $2`.
            let asRe = try? NSRegularExpression(pattern: #"\b([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)\b"#)
            let bodyNS = body as NSString
            let normalised = asRe?.stringByReplacingMatches(
                in: body,
                range: NSRange(location: 0, length: bodyNS.length),
                withTemplate: "$1: $2"
            ) ?? body
            out += head + normalised + tail
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - Rules
    //
    // Order matters: put more specific patterns first. NSRegularExpression
    // uses ICU regex, $1/$2 in replacement, (?m) for multiline.

    private static let rules: [(String, String, NSRegularExpression.Options)] = [

        // ---------- imports ----------

        // import x, { a, b } from "./y"
        // The default ($1) honours __esModule.default; named imports
        // pull from the namespace object directly.
        (#"(?m)^[ \t]*import\s+([A-Za-z_$][\w$]*)\s*,\s*\{([^}]+)\}\s+from\s+['"]([^'"]+)['"]\s*;?"#,
         "const { $2 } = require('$3'), $1 = (() => { const __m = require('$3'); return __m && __m.__esModule ? __m.default : __m; })();",
         []),

        // import x, * as ns from "./y"
        (#"(?m)^[ \t]*import\s+([A-Za-z_$][\w$]*)\s*,\s*\*\s+as\s+([A-Za-z_$][\w$]*)\s+from\s+['"]([^'"]+)['"]\s*;?"#,
         "const $2 = require('$3'), $1 = (() => { const __m = require('$3'); return __m && __m.__esModule ? __m.default : __m; })();",
         []),

        // import { a, b as c } from "./y"   (multi-line allowed)
        (#"(?m)^[ \t]*import\s+\{([\s\S]+?)\}\s+from\s+['"]([^'"]+)['"]\s*;?"#,
         "const { $1 } = require('$2');",
         []),

        // import * as ns from "./y"
        (#"(?m)^[ \t]*import\s+\*\s+as\s+([A-Za-z_$][\w$]*)\s+from\s+['"]([^'"]+)['"]\s*;?"#,
         "const $1 = require('$2');",
         []),

        // import x from "./y"   (default)
        // Use the .default-or-self pattern so we're CJS↔ESM friendly.
        (#"(?m)^[ \t]*import\s+([A-Za-z_$][\w$]*)\s+from\s+['"]([^'"]+)['"]\s*;?"#,
         "const $1 = (() => { const __m = require('$2'); return __m && __m.__esModule ? __m.default : __m; })();",
         []),

        // import "./side-effect"
        (#"(?m)^[ \t]*import\s+['"]([^'"]+)['"]\s*;?"#,
         "require('$1');",
         []),

        // dynamic import("./y") → Promise.resolve(require("./y"))
        (#"\bimport\s*\(\s*(['"])([^'"]+)\1\s*\)"#,
         "Promise.resolve(require('$2'))",
         []),

        // import.meta.url → __filename-as-file-URL (best-effort)
        (#"\bimport\.meta\.url\b"#,
         "('file://' + (typeof __filename !== 'undefined' ? __filename : ''))",
         []),

        // import.meta → a small object literal
        (#"\bimport\.meta\b"#,
         "({ url: ('file://' + (typeof __filename !== 'undefined' ? __filename : '')) })",
         []),

        // ---------- exports ----------

        // export default <expression>
        // Mark the module __esModule so default-import logic above
        // can find .default when the consumer uses ESM-style import.
        (#"(?m)^[ \t]*export\s+default\s+"#,
         "exports.__esModule = true; exports.default = ",
         []),

        // export const/let/var x = ...   →   const x = ...; exports.x = x;
        // The exports assignment is appended at end of statement —
        // we use a lookahead-free approach by matching up to ; or \n
        // and capturing the right-hand side. The replacement appends
        // exports.NAME = NAME; on the same line.
        (#"(?m)^[ \t]*export\s+(const|let|var)\s+([A-Za-z_$][\w$]*)\b"#,
         "exports.__esModule = true; $1 $2 = exports.$2",
         []),

        // export function foo(...) { ... }
        // Rewrite to a const-bound named function expression:
        //
        //   export function foo() { ... }
        //   →
        //   const foo = exports.foo = function foo() { ... };
        //
        // Caveat: function declarations hoist; this const does not.
        // Calls to `foo` before its line will fail. Worth it for the
        // simplicity of a regex-only approach.
        (#"(?m)^[ \t]*export\s+(async\s+)?function(\s*\*)?\s+([A-Za-z_$][\w$]*)"#,
         "exports.__esModule = true; const $3 = exports.$3 = $1function$2 $3",
         []),

        // export class Foo { ... }   →   const Foo = exports.Foo = class Foo { ... }
        (#"(?m)^[ \t]*export\s+class\s+([A-Za-z_$][\w$]*)"#,
         "exports.__esModule = true; const $1 = exports.$1 = class $1",
         []),

        // export { a, b as c }
        // Convert each identifier inside the braces to an exports.X = X
        // assignment. Done with a follow-up pass (callback below).
        // Here we mark it; the actual rewrite runs in `expandNamedExport`.
        (#"(?m)^[ \t]*export\s+\{([^}]+)\}\s*;?"#,
         "__SWIFTJS_EXPORT_LIST__($1);",
         []),
    ]

    // After the regex pass, expand `__SWIFTJS_EXPORT_LIST__(a, b as c)`
    // markers into real assignments.
    public static func expandNamedExports(_ src: String) -> String {
        let pattern = #"__SWIFTJS_EXPORT_LIST__\(([^)]*)\);"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return src }
        let ns = src as NSString
        var out = ""
        var cursor = 0
        re.enumerateMatches(in: src, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let listRange = m.range(at: 1)
            let list = ns.substring(with: listRange)
            let assignments = list
                .split(separator: ",")
                .map { spec -> String in
                    let parts = spec.split(separator: " ").filter { $0 != "as" }
                    let name = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
                    let alias = (parts.count > 1
                        ? parts.last!.trimmingCharacters(in: .whitespaces)
                        : name)
                    return "exports.\(alias) = \(name);"
                }
                .joined(separator: " ")
            let replacement = "exports.__esModule = true; " + assignments
            // Pad with newlines so a multi-line `export { a, b }` block
            // doesn't shift later line numbers in stack traces.
            let original = ns.substring(with: m.range)
            let originalNewlines = original.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            out += replacement
            if originalNewlines > 0 {
                out += String(repeating: "\n", count: originalNewlines)
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - helpers

    private static func regexReplace(
        in src: String,
        pattern: String,
        with template: String,
        options: NSRegularExpression.Options
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            return src
        }
        let ns = src as NSString
        let matches = re.matches(in: src, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return src }

        // Build the output manually so we can pad each replacement
        // with newlines whenever the original match spanned more
        // lines than the template produces. This keeps line numbers
        // in the rewritten source aligned with the user's original
        // source — JSC stack traces and the exception code-frame
        // both point back to the right line.
        var out = ""
        var cursor = 0
        for m in matches {
            let prefix = NSRange(location: cursor, length: m.range.location - cursor)
            out += ns.substring(with: prefix)

            let replacement = re.replacementString(for: m, in: src, offset: 0,
                                                   template: template)
            let originalNewlines = ns.substring(with: m.range)
                .reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            let replacementNewlines = replacement
                .reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            let padding = max(0, originalNewlines - replacementNewlines)
            out += replacement
            if padding > 0 {
                out += String(repeating: "\n", count: padding)
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
