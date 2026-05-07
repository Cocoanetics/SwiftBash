#!/usr/bin/env swift-js
// Concurrent subprocesses via child_process.exec + Promise.all.
//
// Each exec() call dispatches onto a Swift Task.detached and runs
// an independent SwiftBash Shell instance in-process. So three
// `sleep 0.1` calls wall-clock at ~0.1s — they overlap rather
// than serialise. No fork, no exec.
const cp = require('node:child_process');

async function timed(label, fn) {
  const t0 = Date.now();
  await fn();
  console.log(label.padEnd(22), `${Date.now() - t0} ms`);
}

(async () => {
  // Sequential — each await waits for the prior to finish.
  await timed('sequential x3', async () => {
    await cp.exec('sleep 0.1; printf 1');
    await cp.exec('sleep 0.1; printf 2');
    await cp.exec('sleep 0.1; printf 3');
  });

  // Parallel via Promise.all — three Tasks scheduled concurrently.
  await timed('Promise.all x3', async () => {
    const xs = await Promise.all([
      cp.exec('sleep 0.1; printf alpha'),
      cp.exec('sleep 0.1; printf beta'),
      cp.exec('sleep 0.1; printf gamma'),
    ]);
    console.log('   →', xs.map(r => r.stdout).join(', '));
  });

  // Wider fan-out — same wall time.
  await timed('Promise.all x20', async () => {
    await Promise.all(
      Array.from({length: 20}, (_, i) => cp.exec(`sleep 0.1; printf ${i}`))
    );
  });

  // Errors reject. .code, .stdout, .stderr live on the rejected error.
  try {
    await cp.exec('printf "oh no\\n"; exit 3');
  } catch (e) {
    console.log('rejected: code', e.code, '— stdout was:', e.stdout.trim());
  }
})();
