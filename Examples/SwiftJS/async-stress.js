#!/usr/bin/env swift-js
// Stress the runloop drain: nested timers, Promise chains,
// queueMicrotask, setInterval that clears itself, and
// process.exit interrupting the queue.

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

(async () => {
  console.log('1. start');
  await sleep(20);
  console.log('2. after 20ms');

  // Nested timers
  setTimeout(() => {
    console.log('5. nested-outer');
    setTimeout(() => console.log('7. nested-inner'), 10);
  }, 30);

  // queueMicrotask before timer
  queueMicrotask(() => console.log('3. micro-1'));
  queueMicrotask(() => console.log('4. micro-2'));

  // setInterval that self-clears
  let n = 0;
  const id = setInterval(() => {
    n++;
    console.log(`6. interval-${n}`);
    if (n === 2) clearInterval(id);
  }, 5);

  await sleep(60);
  console.log('8. done after 60ms');
})();
