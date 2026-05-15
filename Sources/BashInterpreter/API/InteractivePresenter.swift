import Foundation

/// Embedder hook that lets in-process builtins drive an interactive UI
/// view from the host application.
///
/// SwiftBash itself doesn't own any UI. Builtins that need one
/// (``BashCommandKit/LessCommand``, ``BashCommandKit/MoreCommand``)
/// ask the shell for the active presenter and call it. When no
/// presenter is installed the builtin falls back to its
/// non-interactive behaviour — the same path real `less(1)` /
/// `more(1)` take when their stdout isn't a TTY: bytes pass straight
/// through to stdout, the same as `cat`.
///
/// The protocol is intentionally small. New host-bridging needs add a
/// new method on this protocol rather than another standalone closure
/// on the embedder's hooks struct, so a Shell carries one host handle
/// instead of a sprawling bag of callbacks.
public protocol InteractivePresenter: Sendable {
    /// Render the buffered `request.content` in a host-provided
    /// scrollable view. Returns when the user dismisses it (`q` or
    /// `Esc` in `less` terms). User dismissal is a normal completion
    /// — throw only for setup-time errors.
    ///
    /// Implementations should respect cooperative cancellation:
    /// `Task.isCancelled` becoming `true` (Ctrl+C from the host)
    /// must unblock the call so the calling bash command can return.
    func presentPager(_ request: PagerRequest) async throws
}

/// Pager invocation parameters. Mirrors the subset of `less(1)` /
/// `more(1)` flags that affect rendering rather than I/O.
public struct PagerRequest: Sendable {

    /// `less` vs. `more`. Affects which key bindings the host
    /// advertises — less gets the full set, more gets just
    /// Space / Enter / q.
    public enum Mode: Sendable { case less, more }

    /// The full buffered text to display. Already drained from the
    /// invocation's stdin or file arguments by the builtin — the
    /// presenter just renders it.
    public var content: String

    /// less vs. more semantics.
    public var mode: Mode

    /// Filename (or synthetic label like `(stdin)`) shown in the
    /// status line. `nil` means no title bar.
    public var title: String?

    /// `+G` — start scrolled to the end of the buffer.
    public var startAtEnd: Bool

    /// `-N` — show line numbers in the gutter.
    public var lineNumbers: Bool

    /// `-i` — case-insensitive search matching.
    public var ignoreCaseInSearch: Bool

    /// `-S` — truncate long lines at the viewport edge instead of
    /// wrapping. Default is wrap.
    public var chopLongLines: Bool

    public init(content: String,
                mode: Mode,
                title: String? = nil,
                startAtEnd: Bool = false,
                lineNumbers: Bool = false,
                ignoreCaseInSearch: Bool = false,
                chopLongLines: Bool = false) {
        self.content = content
        self.mode = mode
        self.title = title
        self.startAtEnd = startAtEnd
        self.lineNumbers = lineNumbers
        self.ignoreCaseInSearch = ignoreCaseInSearch
        self.chopLongLines = chopLongLines
    }
}
