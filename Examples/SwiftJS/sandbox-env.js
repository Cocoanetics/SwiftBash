#!/usr/bin/env swift-js
// Run this with `swift-js --sandbox-env sandbox-env.js`.
// Inside, process.env shows only the synthetic minimal set —
// no host secrets, no $HOME of the real user, no $PATH that
// could be used to spawn the wrong binary.
console.log("count:  ", Object.keys(process.env).length);
console.log("keys:   ", Object.keys(process.env).sort().join(", "));
console.log("HOME:   ", process.env.HOME);
console.log("USER:   ", process.env.USER);
console.log("hidden: ", process.env.SECRET_TOKEN ?? "<not visible>");
