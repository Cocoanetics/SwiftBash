import Foundation

/// Version metadata for the SwiftBash interpreter.
///
/// Surfaced through `bash --version`, the `$BASH_VERSION` /
/// `$BASH_VERSINFO` environment variables (set by every freshly
/// constructed ``Shell``), and the `$BASH` path. Scripts that branch
/// on bash version (`if (( BASH_VERSINFO[0] >= 4 )); then …`) get a
/// sensible answer pointing at our 4.x-targeting semantics rather
/// than expanding to empty.
public enum SwiftBashVersion {

    /// `BASH_VERSION` value — major.minor.patch[(build)]-release form,
    /// matching what `/bin/bash` reports. The major/minor advertise
    /// the bash semantics we target (4.x), not the SwiftBash package
    /// version.
    public static let bashVersion = "4.4.20(1)-release"

    /// `BASH_VERSINFO` array — `(major minor patch build release machine)`.
    /// Real bash sets this as a 6-element indexed array; we mirror it.
    public static let bashVersionInfo: [String] = [
        "4", "4", "20", "1", "release", "swift-bash",
    ]

    /// Full `bash --version` banner. Intentionally identifies us as
    /// SwiftBash on the second line so a curious script isn't fooled
    /// into thinking it's running under genuine GNU bash.
    public static let banner: String = """
        GNU bash, version \(bashVersion) (swift-bash)
        Powered by SwiftBash — pure-Swift in-process bash interpreter.
        Bash semantics target version 4.x; see Docs/BashVersionConformance.md.
        """

    /// Path advertised in `$BASH`. Matches macOS's install location so
    /// scripts checking `[ "$BASH" = "/bin/bash" ]` succeed.
    public static let bashPath = "/bin/bash"
}
