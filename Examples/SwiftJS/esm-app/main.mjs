#!/usr/bin/env swift-js
// Multi-file ES module application. Same source runs identically
// on swift-js, node, and bun. Demonstrates:
//   - default + named imports from the same module
//   - namespace imports of a Node builtin
//   - exports re-imported across files
//   - dynamic import()
//   - import.meta.url
import { Greeter } from "./Greeter.mjs";
import * as nodeFs from "node:fs";

const g = new Greeter("swift-js");
console.log(g.greet());
console.log("fs.readFileSync is a", typeof nodeFs.readFileSync);

const meta = import.meta.url;
console.log("running from:", meta.endsWith("main.mjs") ? "main.mjs" : meta);

import("node:path").then(p => {
  console.log("dynamic import: path.join('a','b') =", p.join("a", "b"));
});
