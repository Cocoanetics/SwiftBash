import Foundation

extension SedExecutor {

    func transliterate(_ input: String, source: String, dest: String) -> String {
        let src = Array(source)
        let dst = Array(dest)
        var out = ""
        for char in input {
            if let idx = src.firstIndex(of: char), idx < dst.count {
                out.append(dst[idx])
            } else {
                out.append(char)
            }
        }
        return out
    }
}
