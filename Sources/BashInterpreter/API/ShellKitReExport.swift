// Re-export ShellKit so callers that say `import BashInterpreter`
// keep seeing the runtime-context primitives (`OutputSink`,
// `InputSource`, `Environment`, `Sandbox`, `NetworkConfig`,
// `HostInfo`, `ProcessTable`, `BinCatalog`, `Command`,
// `ClosureCommand`, `ExitStatus`, `Command` registration helpers)
// without an additional `import ShellKit` line.
//
// SwiftBash's `Shell` type subclasses `ShellKit.Shell` and adds
// bash-specific state (errexit, pipefail, shopt options, traps,
// loop / function-call depth, process substitution bookkeeping).
// Most callers don't need to know that — they just see `Shell` and
// `Shell.bashCurrent` and the same property surface that existed before
// the migration.
@_exported import ShellKit
