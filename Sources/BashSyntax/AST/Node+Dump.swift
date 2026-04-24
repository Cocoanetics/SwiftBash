import Foundation

extension Node {
    /// Render a human-readable debug tree of this subtree.
    ///
    /// - Parameters:
    ///   - indent: String used for each level of indentation (default: two spaces).
    ///   - source: When provided, positions are replaced with `s='<substring>'`
    ///     showing the exact source slice each node covers.
    public func dump(indent: String = "  ", source: String? = nil) -> String {
        Dumper(indent: indent, source: source).format(self, level: 0)
    }
}
