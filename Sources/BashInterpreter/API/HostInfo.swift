import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

/// Snapshot of "who is this host?" — values that `whoami`,
/// `hostname`, `id`, `uname`, and similar identity-disclosing
/// commands report. Held on each ``Shell`` so embedders can decide
/// whether to expose the real host's identity or a synthetic one.
///
/// Default is ``synthetic`` — a stable, anonymous answer that leaks
/// nothing. Embedders that genuinely want their script to see the
/// real values call ``real()`` and assign the result to
/// ``Shell/hostInfo``.
public struct HostInfo: Sendable, Equatable {
    /// User login name (`whoami`, `id -un`, `$USER`, `$LOGNAME`).
    public var userName: String
    /// Display name (`id -P` 5th field on macOS). Often the same.
    public var fullUserName: String
    /// Host name (`hostname`, `$HOSTNAME`).
    public var hostName: String
    /// Numeric user ID (`id -u`, `$UID`).
    public var uid: UInt32
    /// Numeric primary group ID (`id -g`).
    public var gid: UInt32
    /// All groups the user belongs to (`id -G`).
    public var groups: [UInt32]
    /// Primary group name (`id -gn`).
    public var groupName: String
    /// `uname -s` — kernel name. Always "Darwin" / "Linux"-style.
    public var kernelName: String
    /// `uname -r` — kernel release version.
    public var kernelRelease: String
    /// `uname -v` — kernel build version string.
    public var kernelVersion: String
    /// `uname -m` — machine hardware (`arm64`, `x86_64`).
    public var machine: String
    /// `uname -n` — network node name; usually equal to ``hostName``.
    public var nodeName: String

    public init(
        userName: String,
        fullUserName: String,
        hostName: String,
        uid: UInt32,
        gid: UInt32,
        groups: [UInt32],
        groupName: String,
        kernelName: String,
        kernelRelease: String,
        kernelVersion: String,
        machine: String,
        nodeName: String
    ) {
        self.userName = userName
        self.fullUserName = fullUserName
        self.hostName = hostName
        self.uid = uid
        self.gid = gid
        self.groups = groups
        self.groupName = groupName
        self.kernelName = kernelName
        self.kernelRelease = kernelRelease
        self.kernelVersion = kernelVersion
        self.machine = machine
        self.nodeName = nodeName
    }

    /// Anonymous, stable values that leak nothing about the host.
    /// This is the **default** for every freshly-constructed `Shell`.
    /// Anything sandboxed (the CLI's `--sandbox` flag, an embedder
    /// running untrusted scripts) keeps this default.
    public static let synthetic = HostInfo(
        userName: "user",
        fullUserName: "user",
        hostName: "sandbox",
        uid: 1000,
        gid: 1000,
        groups: [1000],
        groupName: "users",
        kernelName: "Darwin",
        kernelRelease: "0.0.0",
        kernelVersion: "swift-bash",
        machine: "arm64",
        nodeName: "sandbox")

    /// Capture the host's actual identity via POSIX/Foundation. Use
    /// only when the embedder is intentionally surfacing the real
    /// machine — typically the `swift-bash exec` CLI in non-sandbox
    /// mode, where the user is running their own scripts on their
    /// own machine and expects `whoami` to print their login name.
    public static func real() -> HostInfo {
        let info = ProcessInfo.processInfo
        #if !os(Windows)
        // `ProcessInfo.userName` and `fullUserName` are macOS-only —
        // iOS / tvOS / watchOS don't expose them. Fall back to the
        // POSIX uid → name lookup, then to a generic "user".
        #if os(macOS)
        let user = info.userName
        let full = info.fullUserName.isEmpty ? user : info.fullUserName
        #else
        let user = passwdUserName(uid: UInt32(getuid())) ?? "user"
        let full = user
        #endif
        let host = info.hostName
        let uid = UInt32(getuid())
        let gid = UInt32(getgid())
        // Get supplementary groups via getgroups(2). Cap at NGROUPS_MAX.
        var groups: [UInt32] = [gid]
        var buf = [gid_t](repeating: 0, count: 64)
        let n = getgroups(Int32(buf.count), &buf)
        if n > 0 {
            groups = (0..<Int(n)).map { UInt32(buf[$0]) }
        }
        let groupName = realGroupName(for: gid) ?? "staff"
        let (sysname, release, version, machine, node) = realUname()
        return HostInfo(
            userName: user,
            fullUserName: full,
            hostName: host,
            uid: uid,
            gid: gid,
            groups: groups,
            groupName: groupName,
            kernelName: sysname,
            kernelRelease: release,
            kernelVersion: version,
            machine: machine,
            nodeName: node)
        #else
        let user = winUserName() ?? (info.userName.isEmpty ? "user" : info.userName)
        let host = winComputerName() ?? info.hostName
        let (release, machine) = winKernelInfo()
        return HostInfo(
            userName: user,
            fullUserName: user,
            hostName: host,
            uid: 1000,
            gid: 1000,
            groups: [1000],
            groupName: "users",
            kernelName: "Windows_NT",
            kernelRelease: release,
            kernelVersion: release,
            machine: machine,
            nodeName: host)
        #endif
    }

    #if os(Windows)
    /// Real Windows account name via `GetUserNameW`.
    private static func winUserName() -> String? {
        var bufSize: DWORD = 256
        var buf = [WCHAR](repeating: 0, count: Int(bufSize))
        let ok = buf.withUnsafeMutableBufferPointer { bp -> Bool in
            GetUserNameW(bp.baseAddress, &bufSize)
        }
        guard ok, bufSize > 1 else { return nil }
        // bufSize includes the trailing NUL — drop it.
        return String(decoding: buf.prefix(Int(bufSize) - 1), as: UTF16.self)
    }

    /// Real Windows machine name via `GetComputerNameW`.
    private static func winComputerName() -> String? {
        var bufSize: DWORD = DWORD(MAX_COMPUTERNAME_LENGTH + 1)
        var buf = [WCHAR](repeating: 0, count: Int(bufSize))
        let ok = buf.withUnsafeMutableBufferPointer { bp -> Bool in
            GetComputerNameW(bp.baseAddress, &bufSize)
        }
        guard ok, bufSize > 0 else { return nil }
        return String(decoding: buf.prefix(Int(bufSize)), as: UTF16.self)
    }

    /// Kernel release and machine architecture. Release uses the
    /// Foundation `OperatingSystemVersion` (cheaper than calling
    /// `RtlGetVersion` and lying-via-AppCompat-shim safe).
    private static func winKernelInfo() -> (release: String, machine: String) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let release = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"

        var sysInfo = SYSTEM_INFO()
        GetNativeSystemInfo(&sysInfo)
        let machine: String
        switch Int32(sysInfo.wProcessorArchitecture) {
        case 9 /* PROCESSOR_ARCHITECTURE_AMD64 */:  machine = "x86_64"
        case 12 /* PROCESSOR_ARCHITECTURE_ARM64 */: machine = "arm64"
        case 5 /* PROCESSOR_ARCHITECTURE_ARM */:    machine = "arm"
        case 0 /* PROCESSOR_ARCHITECTURE_INTEL */:  machine = "x86"
        default: machine = "unknown"
        }
        return (release, machine)
    }
    #endif

    #if !os(Windows)
    private static func realGroupName(for gid: UInt32) -> String? {
        guard let entry = getgrgid(gid_t(gid)) else { return nil }
        guard let name = entry.pointee.gr_name else { return nil }
        return String(cString: name)
    }

    /// Resolve a uid to a login name via `getpwuid(3)`. Used on
    /// non-macOS Apple platforms where `ProcessInfo.userName` isn't
    /// available.
    private static func passwdUserName(uid: UInt32) -> String? {
        guard let entry = getpwuid(uid_t(uid)) else { return nil }
        guard let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }

    private static func realUname() -> (String, String, String, String, String) {
        var u = utsname()
        guard uname(&u) == 0 else {
            return ("Darwin", "0.0.0", "swift-bash", "arm64", "sandbox")
        }
        return (
            cString(of: &u.sysname),
            cString(of: &u.release),
            cString(of: &u.version),
            cString(of: &u.machine),
            cString(of: &u.nodename)
        )
    }

    /// Convert a `utsname`-style fixed-size CChar tuple to a String.
    /// Capacity must be a literal so the rebind doesn't capture the
    /// argument by reference and trip overlapping-access.
    private static func cString<T>(of tuple: inout T) -> String {
        return withUnsafePointer(to: &tuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self,
                                  capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
    #endif
}
