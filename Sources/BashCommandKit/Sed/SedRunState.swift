import Foundation

/// Per-line execution state.
struct SedRunState {
    var patternSpace: String = ""
    var holdSpace: String = ""
    var lineNumber: Int = 0
    var totalLines: Int = 0
    var deleted: Bool = false
    var printed: Bool = false
    var quit: Bool = false
    var quitSilent: Bool = false
    var exitCode: Int?
    var errorMessage: String?
    var appendBuffer: [AppendItem] = []
    var changedText: String?
    var substitutionMade: Bool = false
    var lineNumberOutput: [String] = []
    var nCommandOutput: [String] = []
    var restartCycle: Bool = false
    var lastPattern: String?
    var branchRequest: String?
    var linesConsumedInCycle: Int = 0
    var pendingFileReads: [PendingRead] = []
    var pendingFileWrites: [PendingWrite] = []

    enum AppendItem {
        case insert(String)
        case append(String)
    }
    struct PendingRead {
        let filename: String
        let wholeFile: Bool
    }
    struct PendingWrite {
        let filename: String
        let content: String
    }
}
