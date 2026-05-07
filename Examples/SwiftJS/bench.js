#!/usr/bin/env swift-js
// Tiny benchmark suite — same script on swift-js / node / bun.
const fs = require('node:fs');
const os = require('node:os');
const crypto = require('node:crypto');
const path = require('node:path');

const ITER = parseInt(process.argv[2] ?? '1', 10);

function bench(name, fn) {
  const start = Date.now();
  for (let i = 0; i < ITER; i++) fn();
  const ms = Date.now() - start;
  console.log(name.padEnd(28) + ' ' + ms.toString().padStart(6) + ' ms');
}

// 1. Pure CPU
function fib(n) { return n < 2 ? n : fib(n-1) + fib(n-2); }
bench('fib(28)', () => fib(28));

// 2. JSON parse/stringify
const obj = { a: 1, b: [1,2,3,4,5], c: { d: "hello", e: true }, n: 42 };
const json = JSON.stringify(obj);
bench('JSON.parse 1000x', () => {
  for (let i = 0; i < 1000; i++) JSON.parse(json);
});

// 3. Buffer
bench('Buffer.from utf-8 10000x', () => {
  for (let i = 0; i < 10000; i++) Buffer.from('hello world').toString('hex');
});

// 4. Crypto
bench('sha256 hex 10000x', () => {
  for (let i = 0; i < 10000; i++) {
    crypto.createHash('sha256').update('the quick brown fox').digest('hex');
  }
});

// 5. fs round-trip
const tmp = path.join(os.tmpdir(), 'swiftjs-bench-' + process.pid + '.dat');
bench('fs write+read 1000x', () => {
  for (let i = 0; i < 1000; i++) {
    fs.writeFileSync(tmp, 'x'.repeat(64));
    fs.readFileSync(tmp, 'utf-8');
  }
});
fs.rmSync(tmp);

// 6. RegExp
bench('regex test 100000x', () => {
  const re = /^[a-z]+@[a-z]+\.[a-z]+$/;
  for (let i = 0; i < 100000; i++) re.test('user@example.com');
});
