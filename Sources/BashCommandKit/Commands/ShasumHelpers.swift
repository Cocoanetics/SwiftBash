import ArgumentParser
import BashInterpreter
import CryptoKit
import Foundation

// MARK: - md5sum

enum ShasumHelpers {
    /// Lowercase hex of a CryptoKit digest. Generic over digest type so
    /// MD5/SHA1/SHA256 all share one formatter.
    static func hex<D: Digest>(of digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
func runSum(
    files: [String],
    displayFor: (String?) -> String,
    
    hash: (Data) -> String
) async throws -> ExitStatus {
    if files.isEmpty {
        let data = await Shell.current.stdin.readAllData()
        Shell.current.stdout("\(hash(data))  \(displayFor(nil))\n")
        return .success
    }
    var hadError = false
    for f in files {
        do {
            let data = try await Shell.current.readDataAtPath(f)
            Shell.current.stdout("\(hash(data))  \(f)\n")
        } catch {
            Shell.current.stderr("\(f): \(error)\n")
            hadError = true
        }
    }
    return hadError ? .failure : .success
}


