// A small ES module: named exports, a function, and a default.
export const tag = (s) => `[${s}]`;

export function shout(s) {
  return s.toUpperCase() + "!";
}

export default {
  name: "util",
  version: 1,
};
