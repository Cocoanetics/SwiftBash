#!/usr/bin/env swift-js
// A real-ish script written against Node's API surface.
// Runs unchanged on `swift-js`, `node`, and `bun`.

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const util = require('node:util');

// 1. Process info
console.log('platform:', process.platform, process.arch);
console.log('node-ish:', process.version);

// 2. Read this script and hash it (Buffer + base64 + hex)
const me = fs.readFileSync(process.argv[1]);
console.log('script bytes:', me.length);
console.log('first 32 chars:', me.toString('utf-8').slice(0, 32).replace(/\n/g, '\\n'));

// 3. Round-trip a small JSON file in the temp dir
const tmpFile = path.join(os.tmpdir(), 'portable-demo.json');
const payload = { name: process.argv[2] || 'world', when: Date.now(), bytes: [1, 2, 3] };
fs.writeFileSync(tmpFile, JSON.stringify(payload, null, 2));
const back = JSON.parse(fs.readFileSync(tmpFile, 'utf-8'));
console.log(util.format('round-tripped: %j', back));

// 4. URL parsing
const u = new URL('https://example.com:8080/api/items?q=swiftjs#top');
console.log('host:', u.host, 'path:', u.pathname, 'search:', u.search);

// 5. TextEncoder + Buffer
const enc = new TextEncoder();
const buf = Buffer.from(enc.encode('SwiftJS rocks 🎉'));
console.log('hex:', buf.toString('hex').slice(0, 32) + '...');
console.log('back:', buf.toString('utf-8'));

// 6. Async — setTimeout + Promise
console.log('scheduling...');
setTimeout(() => console.log('  fired after 30ms'), 30);
Promise.resolve('promise').then(v => console.log('  resolved:', v));

// 7. Cleanup
setTimeout(() => {
  fs.rmSync(tmpFile, { force: true });
  console.log('done.');
}, 60);
