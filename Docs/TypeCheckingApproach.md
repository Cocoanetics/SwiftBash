# Type checking — a practical approach

A follow-on to [InterpreterArchitecture.md](InterpreterArchitecture.md).
That paper noted type-checking is ~50% of the effort for a Swift
interpreter. This one gets concrete: the data types you need, the
algorithm, the order to build it, and what to skip.

Audience: someone who's written an interpreter for a dynamic
language before and now wants to bolt on type checking for a static
one. Examples are in pseudo-Swift; the algorithms are real.

---

## 1. What "type checking" actually is

Three jobs, often conflated:

1. **Inference.** Given an expression with no annotation, figure
   out its type. `let x = 5 + 3` → `x: Int`.
2. **Checking.** Given an expression and an expected type, verify
   they're compatible. `let x: Int = "hi"` → error.
3. **Resolution.** Pick the right overload, instantiate generics,
   resolve protocol conformances. `Set([1, 2, 3])` →
   `Set<Int>([1, 2, 3])` with `Int: Hashable`.

A complete type checker does all three in one pass. Build them in
the order above — inference first, then bidirectional checking,
then resolution. Each builds on the prior.

The pass runs **between parse and execute**. Input: `SwiftSyntax`
tree. Output: same tree decorated with type information (an
attribute on each node), or a list of diagnostics.

---

## 2. Type representation — the central data type

Everything depends on getting `Type` right. It's the most-used type
in the project. Here's a minimal practical version:

```swift
indirect enum Type: Hashable, Sendable {
    /// A concrete named type: `Int`, `String`, `Foo`, `Array<Int>`.
    case named(String, args: [Type])

    /// `(Int, String, Bool)` — tuple type.
    case tuple([Type])

    /// `(Int, String) -> Bool` — function type.
    case function(parameters: [Param], result: Type, isAsync: Bool, throws: Bool)

    /// Type variable used during inference: `_t1`, `_t2`, …
    /// Resolved to a concrete type by the constraint solver.
    case variable(TypeVariable)

    /// `T` inside a generic function — bound by a parameter list.
    case generic(GenericParameter)

    /// `any Foo` — existential of a protocol.
    case existential(Protocol)

    /// `some Foo` — opaque, anchored to a single value.
    case opaque(Protocol, anchor: AnchorID)

    /// Used for "we don't know yet, fill in later" — a hole.
    /// Distinct from `.variable`: holes can't be unified.
    case unresolved

    struct Param: Hashable, Sendable {
        let label: String?     // external name, e.g. "from" in `from x: Int`
        let type: Type
        let isInOut: Bool
        let hasDefault: Bool
    }
}

final class TypeVariable: Hashable, Sendable {
    let id: Int
    init(id: Int) { self.id = id }
    static func == (a: TypeVariable, b: TypeVariable) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
```

A few decisions worth highlighting:

- **`indirect enum`, not class hierarchy.** Same reason as our AST:
  pattern-matching scales fine, and types are values you compare
  with `==`.
- **`TypeVariable` is a class** (not an `Int` index) so identity
  survives hashing. Two distinct constraints can refer to the same
  variable; `==` on `TypeVariable` means "same hole".
- **No `optional` case.** `Int?` is `.named("Optional", args: [.named("Int")])`.
  Treating optionals as a regular generic type means generic
  machinery handles them automatically. Sugar handling (the `?`
  syntax) is a parser concern.
- **No `nominal` vs `structural` split** for v1. Add it when you
  add structural types (tuples already are; functions already are).

---

## 3. The pass shape

```swift
struct TypeChecker {
    /// One symbol table per active scope. Innermost = .last.
    var scopes: [Scope] = [Scope()]

    /// Constraints accumulated by inference; solved before each
    /// statement / function body completes.
    var constraints: [Constraint] = []

    /// Solved substitutions: type-var id → concrete type.
    var solution: [TypeVariable: Type] = [:]

    /// Diagnostics emitted so far.
    var diagnostics: [Diagnostic] = []

    /// Type-annotated metadata keyed by SwiftSyntax node ID.
    var typeOf: [SyntaxIdentifier: Type] = [:]

    mutating func check(_ source: SourceFile) -> CheckResult { … }
}
```

Pass strategy:

1. **Walk top-level declarations** to populate the global scope.
   Functions, types, protocols, top-level `let`/`var`. This is
   important — it means a function defined later in the file can
   be called from one defined earlier. Same as bash's "definitions
   are values bound into the registry", but here it's a separate
   discovery pass before any expression is checked.
2. **For each declaration in source order:**
   - For a function: check parameters, push a new scope, check the
     body with the return type as the expected type, pop scope.
   - For a `let`/`var`: check the initializer (using any
     annotation as the expected type), bind the name in the
     current scope.
   - For a type/protocol decl: register members in a sub-scope
     keyed by the type name.
3. **Constraint solving** runs at the end of each top-level decl
   (or each function body) to pin down all type variables. Errors
   detected here are reported with the relevant source spans.

---

## 4. Bidirectional checking — the core algorithm

Two mutually recursive functions. The whole rest of the type
checker is built on these.

```swift
extension TypeChecker {
    /// Synthesize: derive the type of `expr` from its sub-pieces.
    /// Used when there's no contextual expected type.
    mutating func synth(_ expr: Expr) -> Type { … }

    /// Check: verify `expr` has the expected type, propagating
    /// the expectation downward to disambiguate sub-expressions.
    mutating func check(_ expr: Expr, against expected: Type) { … }
}
```

The shape of every dispatch:

```swift
mutating func synth(_ expr: Expr) -> Type {
    switch expr {
    case .integerLiteral:
        return .named("Int", args: [])

    case .stringLiteral:
        return .named("String", args: [])

    case .identifier(let name):
        guard let binding = lookup(name) else {
            error("unknown identifier '\(name)'", at: expr.range)
            return .unresolved
        }
        return binding.type

    case .binaryOp(let lhs, let op, let rhs):
        let lhsType = synth(lhs)
        let rhsType = synth(rhs)
        return resolveOperator(op, lhsType, rhsType, at: expr.range)

    case .functionCall(let callee, let args):
        let calleeType = synth(callee)
        return checkCall(calleeType: calleeType, args: args, at: expr.range)

    case .closure(let params, let body):
        // Closures need a context type to resolve unannotated params.
        // If we got here via synth (no context), require all params
        // to have explicit annotations.
        let paramTypes = params.map { p in
            p.annotation ?? { error("missing param type", at: p.range); return .unresolved }()
        }
        let scope = pushScope()
        for (p, t) in zip(params, paramTypes) { scope.bind(p.name, t) }
        let bodyType = synth(body)
        popScope()
        return .function(parameters: paramTypes.map { .init(label: nil, type: $0, …) },
                         result: bodyType, isAsync: false, throws: false)

    // … one case per Expr variant
    }
}

mutating func check(_ expr: Expr, against expected: Type) {
    switch (expr, expected) {
    case (.integerLiteral, .named(let n, _)) where ["Int","Int8","UInt32","Double",…].contains(n):
        // Integer literals are polymorphic — accept any numeric.
        record(expr, type: expected)
        return

    case (.closure(let params, let body), .function(let expectedParams, let expectedResult, _, _)):
        // *Now* we can check unannotated closure params against the
        // expected function type.
        guard params.count == expectedParams.count else {
            error("closure param count mismatch", at: expr.range)
            return
        }
        let scope = pushScope()
        for (p, ep) in zip(params, expectedParams) {
            let paramType = p.annotation ?? ep.type
            scope.bind(p.name, paramType)
            if let ann = p.annotation, ann != ep.type {
                error("param type mismatch", at: p.range)
            }
        }
        check(body, against: expectedResult)
        popScope()

    default:
        // Fall back to synth + unify.
        let actual = synth(expr)
        unify(actual, expected, at: expr.range)
    }
}
```

The two-mode design solves real problems:

- **Numeric literal polymorphism.** `let x: Double = 5` should
  work — but `synth(5)` gives `Int`. With `check(5, against:
  Double)` we know to widen.
- **Trailing closures.** `[1,2,3].map { $0 * 2 }` — the closure's
  param type comes from `map`'s signature. `synth` alone can't
  type the closure; `check` against the expected `(Int) -> T` can.
- **Generic instantiation.** `Set([1, 2, 3])` — the `[Int]`
  argument's type isn't known until we know we're calling the
  `Set<Int>` initializer. Bidirectional checking + constraint
  solving handles it.

---

## 5. Symbol tables and scope

```swift
final class Scope {
    /// Bindings by name. Each binding records its type and the
    /// declaration site (for diagnostics).
    private var bindings: [String: Binding] = [:]
    let parent: Scope?

    init(parent: Scope? = nil) { self.parent = parent }

    func bind(_ name: String, _ binding: Binding) {
        bindings[name] = binding
    }

    func lookup(_ name: String) -> Binding? {
        bindings[name] ?? parent?.lookup(name)
    }
}

struct Binding {
    let type: Type
    let mutability: Mutability    // let / var
    let declRange: Range<Int>
    let kind: Kind

    enum Kind { case localVar, parameter, function, type, module }
}
```

Three things to get right:

- **Linked-list parent pointer**, not a copy-on-write dict per
  scope. Closures need to capture their enclosing scope by
  reference so subsequent mutations are visible.
- **Distinct entry kinds** because resolution rules differ. A type
  named `Foo` and a value named `Foo` (e.g. an enum case) can
  coexist; lookup is context-dependent.
- **Scope is reference-typed**, not value-typed. This matters for
  closures (§7).

---

## 6. Inference via constraint solving

Bidirectional checking handles common cases. For trickier
inference (generic instantiation, multiple-call-site resolution,
overload selection), accumulate constraints and solve them.

```swift
enum Constraint: Hashable {
    /// `t1` must equal `t2` after substitution.
    case equal(Type, Type, at: Range<Int>)

    /// `t` must conform to `protocol`.
    case conforms(Type, Protocol, at: Range<Int>)

    /// `t` must be a subtype of `super`.
    case subtype(Type, Type, at: Range<Int>)

    /// `t` must be one of the listed candidates (overload set).
    case oneOf(Type, [Type], at: Range<Int>)
}
```

Solver:

```swift
mutating func solve() {
    while let c = constraints.popLast() {
        switch c {
        case .equal(let a, let b, let span):
            unify(a, b, at: span)

        case .conforms(let t, let p, let span):
            let resolved = applySolution(t)
            if !conformsTo(resolved, p) {
                error("'\(resolved)' doesn't conform to '\(p)'", at: span)
            }

        case .subtype(let sub, let sup, let span):
            // Class hierarchy + protocol existential coercion.
            …

        case .oneOf(let t, let candidates, let span):
            // Pick the most specific candidate compatible with t.
            …
        }
    }
}

mutating func unify(_ a: Type, _ b: Type, at span: Range<Int>) {
    let aRes = applySolution(a)
    let bRes = applySolution(b)

    switch (aRes, bRes) {
    case (.variable(let v), let other), (let other, .variable(let v)):
        if case .variable(let other2) = other, v == other2 { return }
        if occurs(v, in: other) {
            error("infinite type", at: span)
            return
        }
        solution[v] = other

    case (.named(let n1, let a1), .named(let n2, let a2)):
        guard n1 == n2, a1.count == a2.count else {
            error("'\(aRes)' is not '\(bRes)'", at: span)
            return
        }
        for (x, y) in zip(a1, a2) { unify(x, y, at: span) }

    case (.function(let p1, let r1, _, _), .function(let p2, let r2, _, _)):
        guard p1.count == p2.count else { … }
        for (x, y) in zip(p1, p2) { unify(x.type, y.type, at: span) }
        unify(r1, r2, at: span)

    case (.tuple(let xs), .tuple(let ys)) where xs.count == ys.count:
        for (x, y) in zip(xs, ys) { unify(x, y, at: span) }

    default:
        if aRes == bRes { return }
        error("'\(aRes)' is not '\(bRes)'", at: span)
    }
}
```

Three implementation notes:

- **Occurs check** matters — without it, `T = Array<T>` would
  loop forever and accept inconsistent types.
- **Always `applySolution` before matching** — types may have been
  refined by earlier constraints; matching against stale forms
  produces phantom errors.
- **Solution is monotonic** — once `solution[v] = T`, it never
  changes. If a later constraint disagrees, that's an error.

For Swift's full type system you'd extend this with:
- Subtype constraints for classes (`Cat <: Animal`)
- Protocol conformance lookups
- Default-type rules (literal `5` defaults to `Int`, literal `5.0`
  to `Double`)
- Overload-set narrowing as more info accumulates

The reference is Swift's own `ConstraintSystem` in
`swift-frontend` — but it's industrial-scale. For a teaching
implementation, the algorithm above is enough to handle ~80% of
real Swift code.

---

## 7. The closure / capture problem

In bash, scope is shell-global; closures don't exist. In Swift,
**every function value carries a captured scope reference**, and
the type checker is the one that records what was captured.

```swift
struct Function: Sendable {
    let parameters: [Type.Param]
    let result: Type
    let body: SyntaxNode
    let capturedScope: Scope    // reference, not copy
    let isAsync: Bool
    let isThrowing: Bool
}
```

When the type checker visits a closure expression:

1. Push a new scope whose parent is the *current* scope.
2. Bind each parameter into the new scope with its (annotated or
   inferred) type.
3. Check the body in that scope.
4. Pop the scope, but **keep a reference to it** in the produced
   `Function` value.
5. The runtime later uses that reference to read captured names.

Implications:

- **Scope is a `class` not a `struct`.** Multiple closures that
  capture the same enclosing scope must see each other's mutations
  to captured `var`s.
- **The type checker doesn't decide what's captured.** Whatever
  names are looked up via `parent` during checking determine the
  capture set; record them as a side-effect of `lookup()` if you
  want explicit capture-list diagnostics.
- **Capture lists** (`[weak self]`, `[x]`, etc.) replace specific
  names in the inner scope rather than walking the parent chain.

For a minimal v1, skip capture lists entirely. Pure default
captures (everything visible) is bash-compatible enough that LLM-
generated code will mostly work.

---

## 8. Overload resolution

Swift's overload rules are big. A practical phased approach:

**v1: No overloading.** Each name binds to one type. If the user
declares two `func foo(Int)` and `func foo(String)`, error on the
second declaration. Simple, restrictive, works for most code.

**v2: Distinct-arity / -label overloading only.** `func foo()` vs
`func foo(_ x: Int)` vs `func foo(name x: Int)`. Resolved at the
call site by counting / matching argument labels — no type
unification needed.

**v3: Type-based overloading.** Multiple candidates with the same
arity. Resolution rules:

1. Filter by argument count and labels.
2. For each surviving candidate, attempt to unify the argument
   types with the parameter types. Add resulting constraints.
3. If one candidate produces zero constraints (exact match), pick
   it.
4. Otherwise, prefer the candidate with the *fewest* implicit
   conversions / generic substitutions. This is the "more
   specific" rule.
5. If multiple candidates are equally specific → ambiguity error.

**v4: Generic constraint matching.** `func max<T: Comparable>(...)`.
Now overload resolution interacts with conformance lookup. This is
where Swift's type checker spends most of its real-world cycles.

For a learning interpreter, **stop at v2**. Most real Swift code
doesn't actually use type-based overloading; it uses generics
with constraints, which is structurally simpler than overloading
once you have constraint solving.

---

## 9. Generics in v3

Two constructs to support:

- **Generic functions** — `func swap<T>(_ a: inout T, _ b: inout T)`.
- **Generic types** — `struct Box<T> { … }`.

Internal representation:

```swift
struct GenericSignature: Hashable, Sendable {
    let parameters: [GenericParameter]
    let constraints: [GenericConstraint]
}

struct GenericParameter: Hashable, Sendable {
    let name: String
    let bounds: [Protocol]    // declared via `where T: P, T: Q`
}

enum GenericConstraint: Hashable, Sendable {
    case conforms(GenericParameter, Protocol)        // T: Equatable
    case sameType(Type, Type)                        // T == U.Element
    case classBound(GenericParameter)                // T: AnyObject
}
```

When a generic function is called:

1. Allocate fresh `TypeVariable`s for each generic parameter.
2. Substitute them through the function's signature.
3. Check the call against the substituted signature.
4. Add constraints encoding the generic's `where`-clause.
5. Solve.

Example: `func max<T: Comparable>(_ a: T, _ b: T) -> T` called as
`max(3, 4)`.

- Fresh `_T0` for `T`.
- Signature becomes `(_T0, _T0) -> _T0` plus constraint
  `_T0: Comparable`.
- Call adds constraints `_T0 = Int` (from `3`) and `_T0 = Int`
  (from `4`).
- Solver picks `_T0 = Int`.
- Conformance check: `Int: Comparable` → yes.
- Result type: `Int`.

This is the heart of Hindley-Milner-flavored inference. Once it
works for one example, it works for all.

---

## 10. Diagnostics — get this right early

Bad type errors are the worst part of using a typed language.
Three principles:

1. **Always cite the source span.** Every constraint, every
   binding, every type carries a `Range<Int>` (or `SourceLocation`
   if you have line/col tracking). Errors point at exact offsets.
2. **Show what you have and what you expected.** Not "type
   mismatch", but `expected 'String', got 'Int'`. Pretty-print
   types with their context (`Array<Int>` not `_t0`).
3. **Recover and keep checking.** When you hit an error, mark the
   relevant node as `.unresolved` and continue. The user wants to
   see all errors in one pass, not fix-recompile-repeat.

Diagnostic sketch:

```swift
struct Diagnostic {
    enum Severity { case error, warning, note }
    let severity: Severity
    let message: String
    let primary: SourceSpan
    let related: [(SourceSpan, String)] = []   // "function declared here", etc.
    let fixIts: [FixIt] = []
}
```

For really good errors, attach **notes** pointing at the
*declaration* of mismatched types. "Expected `String` here, but
the parameter was declared as `Int` at line 17."

---

## 11. Order of operations

Build incrementally. Each step works end-to-end before the next
starts.

1. **Type representation + scope.** Just the data types, no logic.
2. **Synthesise** for literals and identifiers. Run on hand-built
   AST fragments; assert types come out right.
3. **Synthesise + check** for `let x: T = expr`. Now you have
   bidirectional flow.
4. **Function declarations + bodies.** Push/pop scope, check
   return type. No generics yet.
5. **Function calls.** Match argument types against parameter
   types. No overloading.
6. **Constraint accumulation + unification.** Refactor §3 to emit
   constraints instead of unifying eagerly; add the solver. Most
   prior tests should still pass.
7. **Type declarations** (`struct Foo { … }`). Now methods can be
   resolved by type lookup.
8. **Generic functions** with single parameters.
9. **Generic types**.
10. **Protocol declarations + conformance checking**.
11. **Existentials and opaque types**.

Stop at any milestone; the result is a useful subset. After (6)
you can already type-check a substantial chunk of real Swift code.

---

## 12. Testing

Same shape as SwiftBash's tests:

- **Unit tests for each `synth` / `check` case.** Hand-build small
  expression trees, assert the resulting type.
- **Inference tests** with known-tricky cases: numeric literal
  promotion, closure inference from context, generic instantiation,
  recursive functions.
- **Negative tests**: expressions that should fail with a specific
  diagnostic at a specific span. Match the error text.
- **End-to-end snapshot tests**: feed real Swift source through
  parse + type-check + render the type-decorated AST. Check the
  rendering against a frozen baseline. When you change behavior,
  diff is exactly what changed.

The discipline that paid off in SwiftBash: **every behavior change
gets a test added in the same commit**. ~1800 tests for ~5 KLOC of
runtime code. The type checker for a Swift subset will probably
end up with a similar ratio — plan for it.

---

## 13. What to skip

A type checker that handles 100% of Swift is a person-decade.
Cuts that get you to "useful" much faster:

- **No protocol witness tables for v1.** Just declared
  conformances; runtime dispatch is direct.
- **No conditional conformance** (`extension Array: Equatable
  where Element: Equatable`). Punts a lot of generic-system
  complexity.
- **No `any` / `some`** (existentials, opaque types). Generics
  with concrete arguments only.
- **No `@autoclosure`, `@escaping`, `@inlinable`, `@available`.**
  Keep attribute parsing to the minimum the runtime needs.
- **No operator overloading.** Built-in operators only, hard-coded
  rules per arg-type pair.
- **No `subscript` declarations.** `array[i]` and `dict[k]` are
  builtins.
- **No property wrappers, key paths, dynamic member lookup.**
  Each is its own thicket.
- **No async/await checking.** Treat everything as sync; the
  runtime handles `await` as a no-op for v1.
- **No `inout` checking.** Allow `inout` syntactically; treat
  parameters as references at runtime.

What this leaves you with: **classes with methods and stored
properties; structs with the same; generic functions and types
with simple constraints; closures with inferred captures; arrays
and dictionaries; basic inheritance and protocols.** Roughly the
"first hundred pages of the Swift book" subset. That's enough to
type-check most of what an LLM agent would write.

---

## 14. Tools that exist already

Don't reinvent these:

- **`swift-syntax`** — full parser. Returns a typed syntax tree
  with concrete node types per construct. Use this; never write
  your own Swift parser.
- **`SwiftCompilerSources`** (in the swift-frontend repo) — has
  the actual production type checker if you want to read it.
  Massive but instructive.
- **`SwiftFormat`** / **`swift-syntax`'s `BasicFormat`** — useful
  for prettyprinting types in diagnostics.

Things to *not* depend on for the type checker itself:
- The Swift compiler's `.swiftmodule` files. Roll your own module
  system; reading swiftmodule is its own giant project (binary
  serialization format, ABI details, etc.).

---

## 15. Sketch of the v1 milestone

After ~2-4 weeks of focused work, a v1 type checker should:

- Handle expression types: literals, identifiers, function calls,
  binary ops, member access, array/tuple literals.
- Handle statement types: `let`, `var`, `return`, `if`, `while`,
  `for`, `func`.
- Type-check function signatures: parameters, return type,
  `throws` annotation.
- Type-check function bodies: every expression has a type, every
  control path returns the declared type.
- Issue diagnostics with spans for type mismatches.
- Pass through to the interpreter a typed AST that runtime code
  can use without ambiguity.

What it won't do yet: generics, protocols, overloading. Those are
v2. But it'll already type-check single-file scripts that don't
use those features — which is most LLM-generated Swift code.

---

## 16. Ten-line summary

1. Type checking is inference + checking + resolution. Build in
   that order.
2. `Type` is one indirect enum. `TypeVariable` is a class for
   identity-during-inference.
3. Bidirectional algorithm: `synth(_:)` and `check(_:against:)`.
   These two functions are the spine.
4. Scopes are reference-typed (closures capture them). Lookup
   walks `parent`.
5. Eager unification handles 80% of cases; switch to constraints +
   solver once you need overload resolution and generics.
6. Functions carry their captured scope by reference. The type
   checker decides what's captured implicitly.
7. Generic instantiation = fresh type variables + substitute through
   signature + add `where`-clause constraints + solve.
8. Diagnostics need source spans, expected-vs-actual context, and
   recovery (don't bail on first error).
9. Build incrementally; stop at any milestone for a useful subset.
10. Use `swift-syntax`. Don't write a Swift parser.
