#if !os(Windows)

import Foundation
import BashInterpreter

// `node:fs` (sync) + `node:fs/promises` (async wrappers) live here.
// Split from `Modules.swift` to keep that file focused on require()
// plumbing and the orchestration table.

extension JSRuntime {

    /// `node:fs/promises` — async wrappers over the sync fs ops.
    /// Built in JS so each function returns a real Promise without
    /// needing a Swift round-trip.
    func makeFsPromisesModule(syncFs: JSValue) -> JSValue {
        // Stash the sync module under a unique global key so the JS
        // factory can grab it, then build the async surface.
        let key = "__swiftjs_sync_fs"
        setGlobal(key, syncFs)
        let source = #"""
        (() => {
          const fs = globalThis.__swiftjs_sync_fs;
          const wrap = (name) => (...args) => {
            try { return Promise.resolve(fs[name](...args)); }
            catch (e) { return Promise.reject(e); }
          };
          const out = {};
          for (const n of [
            "readFileSync","writeFileSync","appendFileSync",
            "readdirSync","mkdirSync","rmSync","unlinkSync","statSync",
          ]) {
            // Drop the Sync suffix.
            out[n.replace(/Sync$/, "")] = wrap(n);
          }
          delete globalThis.__swiftjs_sync_fs;
          return out;
        })()
        """#
        return context.evaluateScript(source)!
    }

    // MARK: - fs

    // Body assembles the full `node:fs` surface — each of the ~8
    // sync ops is a single closure literal that can't be meaningfully
    // factored without obscuring the structure.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func makeFsModule() -> JSValue {
        let fsObject = JSValue(newObjectIn: context)!

        // readFileSync: returns Buffer if no encoding, String otherwise.
        let readFileSync = block { [weak self] args in
            guard let self, let path = args.first?.toString() else { return nil }
            let opts: JSValue? = args.count >= 2 ? args[1] : nil
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .read) }
            } catch {
                return self.throwSandboxDenial(error, syscall: "open", path: path)
            }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
                let encoding = Self.encodingArg(from: opts)
                if let encoding {
                    return Self.decode(data, encoding: encoding)
                }
                let bufferCtor = self.context.objectForKeyedSubscript("Buffer")!
                let bytes = Array(data) as [UInt8]
                return bufferCtor.invokeMethod("from", withArguments: [bytes])!
            } catch {
                return self.throwSystemError(error, syscall: "open", path: path)
            }
        }
        fsObject.setObject(readFileSync, forKeyedSubscript: "readFileSync")

        let writeFileSync = block { [weak self] args in
            guard let self, args.count >= 2,
                  let path = args[0].toString()
            else { return false }
            let value = args[1]
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .write) }
            } catch {
                _ = self.throwSandboxDenial(error, syscall: "open", path: path)
                return false
            }
            do {
                let data = Self.dataForWrite(value)
                try data.write(to: URL(fileURLWithPath: resolved))
                return true
            } catch {
                _ = self.throwSystemError(error, syscall: "open", path: path)
                return false
            }
        }
        fsObject.setObject(writeFileSync, forKeyedSubscript: "writeFileSync")

        let appendFileSync = block { [weak self] args in
            guard let self, args.count >= 2,
                  let path = args[0].toString()
            else { return false }
            let value = args[1]
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .write) }
            } catch {
                _ = self.throwSandboxDenial(error, syscall: "open", path: path)
                return false
            }
            let data = Self.dataForWrite(value)
            let url = URL(fileURLWithPath: resolved)
            do {
                if FileManager.default.fileExists(atPath: resolved) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                } else {
                    try data.write(to: url)
                }
                return true
            } catch {
                _ = self.throwSystemError(error, syscall: "open", path: path)
                return false
            }
        }
        fsObject.setObject(appendFileSync, forKeyedSubscript: "appendFileSync")

        let existsSync = block { [weak self] args in
            // existsSync swallows errors by spec — Node returns `false`
            // for a path it can't stat. Mirror that behaviour for a
            // sandbox denial: the script learns nothing about whether
            // the path exists, only that it can't see it.
            guard let path = args.first?.toString() else { return false }
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self?.awaitSync { try await authorizePath(resolved, for: .read) }
            } catch {
                return false
            }
            return FileManager.default.fileExists(atPath: resolved)
        }
        fsObject.setObject(existsSync, forKeyedSubscript: "existsSync")

        let readdirSync = block { [weak self] args in
            guard let self, let path = args.first?.toString() else { return nil }
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .read) }
            } catch {
                return self.throwSandboxDenial(error, syscall: "scandir", path: path)
            }
            do {
                return try FileManager.default.contentsOfDirectory(atPath: resolved)
            } catch {
                _ = self.throwSystemError(error, syscall: "scandir", path: path)
                return nil
            }
        }
        fsObject.setObject(readdirSync, forKeyedSubscript: "readdirSync")

        let mkdirSync = block { [weak self] args in
            guard let self, let path = args.first?.toString() else { return false }
            let opts: JSValue? = args.count >= 2 ? args[1] : nil
            let recursive = opts?.objectForKeyedSubscript("recursive")?.toBool() ?? false
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .write) }
            } catch {
                _ = self.throwSandboxDenial(error, syscall: "mkdir", path: path)
                return false
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: resolved,
                    withIntermediateDirectories: recursive
                )
                return true
            } catch {
                _ = self.throwSystemError(error, syscall: "mkdir", path: path)
                return false
            }
        }
        fsObject.setObject(mkdirSync, forKeyedSubscript: "mkdirSync")

        let rmSync = block { [weak self] args in
            guard let self, let path = args.first?.toString() else { return false }
            let opts: JSValue? = args.count >= 2 ? args[1] : nil
            let force = opts?.objectForKeyedSubscript("force")?.toBool() ?? false
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .delete) }
            } catch {
                // `force: true` would normally swallow ENOENT — but a
                // sandbox denial is policy, not a missing file, so
                // surface it regardless.
                _ = self.throwSandboxDenial(error, syscall: "unlink", path: path)
                return false
            }
            do {
                try FileManager.default.removeItem(atPath: resolved)
                return true
            } catch {
                if !force {
                    _ = self.throwSystemError(error, syscall: "unlink", path: path)
                }
                return false
            }
        }
        fsObject.setObject(rmSync, forKeyedSubscript: "rmSync")
        fsObject.setObject(rmSync, forKeyedSubscript: "unlinkSync")

        let statSync = block { [weak self] args in
            guard let self, let path = args.first?.toString() else { return nil }
            let resolved = resolveAgainstShellCWD(path)
            do {
                try self.awaitSync { try await authorizePath(resolved, for: .read) }
            } catch {
                return self.throwSandboxDenial(error, syscall: "stat", path: path)
            }
            let fileManager = FileManager.default
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved, isDirectory: &isDir) else {
                return self.throwJSError(
                    "ENOENT: no such file or directory, stat '\(path)'",
                    code: "ENOENT",
                    extras: [
                        "errno": Int(-ENOENT),
                        "syscall": "stat",
                        "path": path
                    ]
                )
            }
            let attrs = (try? fileManager.attributesOfItem(atPath: resolved)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let isDirectory = isDir.boolValue
            let obj = JSValue(newObjectIn: self.context)!
            obj.setObject(size, forKeyedSubscript: "size")
            obj.setObject(mtime * 1000, forKeyedSubscript: "mtimeMs")
            let isDirImpl = self.block { _ in isDirectory }
            let isFileImpl = self.block { _ in !isDirectory }
            obj.setObject(isDirImpl, forKeyedSubscript: "isDirectory")
            obj.setObject(isFileImpl, forKeyedSubscript: "isFile")
            return obj
        }
        fsObject.setObject(statSync, forKeyedSubscript: "statSync")

        return fsObject
    }

    static func encodingArg(from opts: JSValue?) -> String? {
        guard let opts else { return nil }
        if opts.isString { return opts.toString() }
        if opts.isObject,
           let enc = opts.objectForKeyedSubscript("encoding"),
           enc.isString {
            return enc.toString()
        }
        return nil
    }

    static func decode(_ data: Data, encoding: String) -> String {
        switch encoding.lowercased() {
        case "utf-8", "utf8":
            return String(data: data, encoding: .utf8) ?? ""
        case "ascii":
            return String(data: data, encoding: .ascii) ?? ""
        case "base64":
            return data.base64EncodedString()
        case "hex":
            return data.map { String(format: "%02x", $0) }.joined()
        default:
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// Convert a string|Buffer|Uint8Array JSValue to Data for writing.
    static func dataForWrite(_ value: JSValue) -> Data {
        if value.isString {
            return Data((value.toString() ?? "").utf8)
        }
        if let bytes = value.toArray() as? [NSNumber] {
            return Data(bytes.map { $0.uint8Value })
        }
        return Data((value.toString() ?? "").utf8)
    }
}

#endif  // !os(Windows)
