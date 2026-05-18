import Foundation
import ShellKit

/// Result builder for ``Shell/install(at:_:)`` — collects a list of
/// ``Command`` values under one install directory.
///
/// ```swift
/// shell.install(at: "/usr/local/bin") {
///     DeployTool()
///     LintTool()
///     if includeFormatter { FormatTool() }   // buildOptional
///     for tool in extras { tool }            // buildArray
/// }
/// ```
///
/// `Command` values are the only thing the bundle accepts, so no
/// `buildExpression` overload is needed.
@resultBuilder
public enum CommandBundleBuilder {
    public static func buildBlock(_ parts: Command...) -> [Command] { parts }
    public static func buildArray(_ parts: [[Command]]) -> [Command] {
        parts.flatMap { $0 }
    }
    public static func buildOptional(_ part: [Command]?) -> [Command] {
        part ?? []
    }
    public static func buildEither(first: [Command]) -> [Command] { first }
    public static func buildEither(second: [Command]) -> [Command] { second }
}
