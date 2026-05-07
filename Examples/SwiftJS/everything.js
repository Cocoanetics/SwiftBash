#!/usr/bin/env swift-js
// Single script exercising every layer: fs, path, os, util, crypto,
// child_process, Buffer, TextEncoder, URL, timers, Promise, fetch.
// Goal: produce byte-identical output on swift-js, node, and bun.

const fs    = require('node:fs');
const path  = require('node:path');
const os    = require('node:os');
const util  = require('node:util');
const crypto = require('node:crypto');
const cp    = require('node:child_process');

const log = (...args) => console.log(...args);
const PAD = (s, n = 14) => String(s).padEnd(n);

// 1. process / os
log('==', 'process / os');
log(PAD('platform:'), process.platform, process.arch);
log(PAD('argv[2]:'),  process.argv[2] ?? '<none>');
log(PAD('os.EOL:'),   JSON.stringify(os.EOL));
log(PAD('os.tmpdir:'), typeof os.tmpdir());

// 2. path
log('==', 'path');
log(PAD('join:'),     path.join('a','b','c.txt'));
log(PAD('dirname:'),  path.dirname('/x/y/z.js'));
log(PAD('basename:'), path.basename('/x/y/z.js', '.js'));
log(PAD('extname:'),  path.extname('z.tar.gz'));

// 3. fs round trip
log('==', 'fs');
const tmp = path.join(os.tmpdir(), 'swiftjs-everything.json');
const payload = { who: process.argv[2] ?? 'world', n: 42 };
fs.writeFileSync(tmp, JSON.stringify(payload));
const back = JSON.parse(fs.readFileSync(tmp, 'utf-8'));
log(PAD('round-trip:'), back.who, back.n);
const buf = fs.readFileSync(tmp);
log(PAD('isBuffer:'),   Buffer.isBuffer(buf), 'len=' + buf.length);
fs.rmSync(tmp);

// 4. Buffer + encoding
log('==', 'Buffer / encoding');
const hello = Buffer.from('Héllo 🎉');
log(PAD('utf-8 len:'), hello.length);
log(PAD('hex:'),       hello.toString('hex'));
log(PAD('base64:'),    hello.toString('base64'));
log(PAD('roundtrip:'), Buffer.from(hello.toString('base64'), 'base64').toString('utf-8'));

const enc = new TextEncoder().encode('abc');
log(PAD('TextEnc:'),   Array.from(enc).join(','));
log(PAD('TextDec:'),   new TextDecoder().decode(enc));

// 5. URL  (use a non-default port so node/bun don't strip ":443")
log('==', 'URL');
const u = new URL('https://example.com:8443/api?k=v#frag');
log(PAD('host:'),     u.host);
log(PAD('pathname:'), u.pathname);
log(PAD('search:'),   u.search);
log(PAD('hash:'),     u.hash);

// 6. crypto
log('==', 'crypto');
log(PAD('sha256:'),   crypto.createHash('sha256').update('swift-js').digest('hex'));
log(PAD('md5:'),      crypto.createHash('md5').update('swift-js').digest('hex'));
log(PAD('hmac:'),     crypto.createHmac('sha256','k').update('swift-js').digest('hex'));
log(PAD('rand-len:'), crypto.randomBytes(8).length);

// 7. child_process — pipeline through bash. Node returns Buffer
// by default; pass encoding so all three runtimes return string.
log('==', 'child_process');
const out = cp.execSync('printf "alpha\\nbeta\\ngamma\\n" | grep a | wc -l', { encoding: 'utf-8' });
log(PAD('grep|wc:'), out.trim());

// 8. util.format
log('==', 'util');
log(PAD('format:'), util.format('%s=%d (%j)', 'x', 7, [1,2,3]));

// 9. timers + Promise ordering
log('==', 'async');
log(PAD('start:'), 'sync done');
queueMicrotask(() => log(PAD('micro:'), '1'));
Promise.resolve().then(() => log(PAD('promise:'), '1'));
setTimeout(() => log(PAD('timer:'), '0ms'), 0);
setTimeout(() => log(PAD('timer:'), '20ms'), 20);
