#if !os(Windows)

import Foundation

// `node:path` — pure-JS module split out of `Modules.swift`.

extension JSRuntime {

    // MARK: - path

    func makePathModule() -> JSValue {
        // Implemented in JS for pure-string ops (matches Node).
        let source = #"""
        ({
          sep: "/",
          delimiter: ":",
          join(...parts) {
            const filtered = parts.filter(p => p && p.length > 0);
            if (filtered.length === 0) return ".";
            return filtered.join("/").replace(/\/+/g, "/");
          },
          basename(p, ext) {
            const i = p.lastIndexOf("/");
            let base = i < 0 ? p : p.slice(i + 1);
            if (ext && base.endsWith(ext)) base = base.slice(0, -ext.length);
            return base;
          },
          dirname(p) {
            const i = p.lastIndexOf("/");
            if (i < 0) return ".";
            if (i === 0) return "/";
            return p.slice(0, i);
          },
          extname(p) {
            const i = p.lastIndexOf("/");
            const base = i < 0 ? p : p.slice(i + 1);
            const j = base.lastIndexOf(".");
            return j <= 0 ? "" : base.slice(j);
          },
          isAbsolute(p) { return p.startsWith("/"); },
          resolve(...parts) {
            let resolved = process.cwd();
            for (const p of parts) {
              if (!p) continue;
              if (p.startsWith("/")) resolved = p;
              else resolved = resolved + "/" + p;
            }
            return resolved.replace(/\/+/g, "/");
          },
          parse(p) {
            const i = p.lastIndexOf("/");
            const dir = i <= 0 ? (i === 0 ? "/" : "") : p.slice(0, i);
            const base = i < 0 ? p : p.slice(i + 1);
            const j = base.lastIndexOf(".");
            const ext = j <= 0 ? "" : base.slice(j);
            const name = ext ? base.slice(0, -ext.length) : base;
            return { root: p.startsWith("/") ? "/" : "", dir, base, ext, name };
          },
        })
        """#
        return context.evaluateScript(source)!
    }
}

#endif  // !os(Windows)
