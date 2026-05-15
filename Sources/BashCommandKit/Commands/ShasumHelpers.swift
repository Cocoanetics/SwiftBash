import ArgumentParser
import BashInterpreter
import Crypto
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
        let data = await Shell.bashCurrent.stdin.readAllData()
        Shell.bashCurrent.stdout("\(hash(data))  \(displayFor(nil))\n")
        return .success
    }
    var hadError = false
    for file in files {
        // `md5sum *.bin` over a thousand files: yield to the executor
        // so a kill from the parent shell can land between files.
        try Task.checkCancellation()
        do {
            let data = try await Shell.bashCurrent.readDataAtPath(file)
            Shell.bashCurrent.stdout("\(hash(data))  \(file)\n")
        } catch {
            Shell.bashCurrent.stderr("\(file): \(error)\n")
            hadError = true
        }
    }
    return hadError ? .failure : .success
}
