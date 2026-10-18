import Foundation

extension Shell {

    /// Resolve a subscripted array reference.
    ///
    /// - Associative array (`declare -A`): subscript is a string key.
    /// - Indexed array: `${arr[N]}` returns the Nth element (empty
    ///   for unset slots), `${arr[@]}` / `${arr[*]}` join set elements
    ///   in index order.
    func arrayElementLookup(_ name: String,
                            `subscript` sub: String) -> String {
        if let assoc = environment.associativeArrays[name] {
            switch sub {
            case "@", "*":
                return assoc.values.joined(separator: " ")
            default:
                return assoc[sub] ?? ""
            }
        }
        if let array = environment.arrays[name] {
            switch sub {
            case "@", "*":
                return array.elementsInOrder.joined(separator: " ")
            default:
                if let index = Int(sub) {
                    // Bash 4.3+: negative indices count from the end of
                    // the *highest* set slot, not from `count`. So for
                    // `arr[0]=a; arr[5]=b`, `${arr[-1]}` is `b` (the
                    // value at index 5, not index 4).
                    let resolved = index >= 0 ? index
                        : ((array.entries.keys.max() ?? -1) + 1 + index)
                    return array[resolved] ?? ""
                }
                return ""
            }
        }
        // Scalar fallback: `${name[0]}` reads the scalar value at
        // index 0; everything else is empty.
        if sub == "0" || sub == "@" || sub == "*" {
            return scalarValue(name) ?? ""
        }
        return ""
    }

    /// A scalar's value, dynamic ones (`$UID`, `$RANDOM`, …) included;
    /// `nil` when unset.
    func scalarValue(_ name: String) -> String? {
        dynamicVariable(name) ?? environment.variables[name]
    }
}
