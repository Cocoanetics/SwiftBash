#if !os(Windows)

import Foundation
import BashInterpreter

// `node:os` — Swift-backed because it pulls identity values
// (homedir, tmpdir, hostname, platform, arch) from the bound shell's
// sandbox or the host. Split from `Modules.swift` to keep the
// orchestration file short.

extension JSRuntime {

    // MARK: - os

    func makeOsModule() -> JSValue {
        let osObject = JSValue(newObjectIn: context)!

        // Identity redirects: when an embedder has bound a non-default
        // Shell, route through `Shell.current` so a sandboxed script
        // sees the synthetic identity rather than the host's. Under
        // `Shell.processDefault` (standalone `swift-js` CLI) we keep
        // the legacy host-API answers.
        osObject.setObject(block { _ in Self.osHomedir() }, forKeyedSubscript: "homedir")
        osObject.setObject(block { _ in Self.osTmpdir() }, forKeyedSubscript: "tmpdir")
        osObject.setObject(block { _ in Self.osHostname() }, forKeyedSubscript: "hostname")
        osObject.setObject(block { _ in Self.osPlatform() }, forKeyedSubscript: "platform")
        osObject.setObject(block { _ in Self.osArch() }, forKeyedSubscript: "arch")

        osObject.setObject("\n", forKeyedSubscript: "EOL")
        return osObject
    }

    private static func osHomedir() -> String {
        if Shell.current === Shell.processDefault {
            return NSHomeDirectory()
        }
        if let sandboxHome = Shell.current.sandbox?.homeDirectory {
            // Region URLs are host-spelled (consumers hand them to
            // Foundation); what the script SEES folds back to the
            // virtual spelling under a path-mapped sandbox — the
            // same answer `$HOME` carries.
            return Shell.current.displayPath(for: sandboxHome)
        }
        return Shell.current.environment.variables["HOME"] ?? NSHomeDirectory()
    }

    private static func osTmpdir() -> String {
        if Shell.current === Shell.processDefault {
            return NSTemporaryDirectory()
        }
        if let sandboxTmp = Shell.current.sandbox?.temporaryDirectory {
            // Fold the per-instance host dir back to `/tmp` under a
            // path-mapped sandbox (#82 / #83): the host path must not
            // leak, and anything the script does with the answer
            // (`fs.writeFileSync(os.tmpdir() + "/x")`) re-translates
            // through `resolveAgainstShellCWD` onto the same dir.
            return Shell.current.displayPath(for: sandboxTmp)
        }
        return NSTemporaryDirectory()
    }

    private static func osHostname() -> String {
        if Shell.current === Shell.processDefault {
            return ProcessInfo.processInfo.hostName
        }
        return Shell.current.hostInfo.hostName
    }

    private static func osPlatform() -> String {
        #if os(macOS)
        return "darwin"
        #elseif os(iOS)
        return "ios"
        #elseif os(Linux)
        return "linux"
        #elseif os(Android)
        return "android"
        #else
        return "unknown"
        #endif
    }

    private static func osArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x64"
        #else
        return "unknown"
        #endif
    }
}

#endif  // !os(Windows)
