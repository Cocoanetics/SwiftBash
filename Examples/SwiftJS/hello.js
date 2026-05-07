#!/usr/bin/env swift-js
// Demo: arguments, env, fs, JSON.
const [, , name = "world"] = process.argv;
console.log(`hello, ${name}!`);
console.log("cwd:", process.cwd());
console.log("home:", os.homedir());
console.log("argv:", JSON.stringify(process.argv));

// Round-trip a tiny JSON file.
const tmpFile = path.join(os.tmpdir(), "swiftjs-demo.json");
fs.writeFileSync(tmpFile, JSON.stringify({ greeting: name, pid: 0 }, null, 2));
const back = JSON.parse(fs.readFileSync(tmpFile, "utf-8"));
console.log("round-tripped:", back.greeting);
