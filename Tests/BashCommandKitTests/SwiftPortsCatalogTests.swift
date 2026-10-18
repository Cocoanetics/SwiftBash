#if !os(Android)
import Testing
@testable import BashInterpreter
import SwiftPortsCommands

/// `registerSwiftPortsCommands()` installs every SwiftPorts port through
/// the catalog-default ``Shell/install(_:)``, which traps when the name
/// has no ``BinCatalog`` entry. A port added upstream without a catalog
/// path therefore takes down every shell that registers the standard
/// commands — SwiftPorts' `ssh` did exactly that to embedders that track
/// SwiftPorts `main`.
@Suite struct SwiftPortsCatalogTests {

    @Test func everySwiftPortsCommandHasACatalogPath() {
        let missing = SwiftPortsCommands.argumentParserCommands
            .map(\.name)
            .filter { BinCatalog.knownPaths[$0] == nil }
        #expect(missing.isEmpty, "add these to BinCatalog.knownPaths: \(missing)")
    }

    @Test func sshLivesInUsrBin() {
        #expect(BinCatalog.knownPaths["ssh"] == "/usr/bin/ssh")
    }
}
#endif
