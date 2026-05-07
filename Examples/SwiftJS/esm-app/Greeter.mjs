// Mixes a default-import (the meta object) with named imports
// from the same module, then exports a class.
import util, { tag, shout } from "./util.mjs";

export class Greeter {
  constructor(who) { this.who = who; }
  greet() {
    return shout(tag(this.who) + " hello, from " + util.name + " v" + util.version);
  }
}
