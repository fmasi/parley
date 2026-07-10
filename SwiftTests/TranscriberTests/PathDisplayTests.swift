import Testing
import Foundation
@testable import TranscriberCore

@Suite("PathDisplay")
struct PathDisplayTests {
    private var home: String { (NSHomeDirectory() as NSString).standardizingPath }

    @Test func homeItselfBecomesTilde() {
        #expect(abbreviatedDisplayPath(home) == "~")
    }

    @Test func pathUnderHomeIsAbbreviated() {
        #expect(abbreviatedDisplayPath("\(home)/Documents/Recordings") == "~/Documents/Recordings")
    }

    @Test func tildeInputIsExpandedThenReabbreviated() {
        #expect(abbreviatedDisplayPath("~/Documents") == "~/Documents")
    }

    @Test func pathOutsideHomeIsUntouched() {
        #expect(abbreviatedDisplayPath("/Volumes/Archive/Recordings") == "/Volumes/Archive/Recordings")
    }

    /// The old implementation used `replacingOccurrences`, which rewrote the
    /// home path anywhere it appeared — including nested inside the path.
    /// Only a leading match may be abbreviated.
    @Test func homePathNestedInsideIsNotAbbreviated() {
        let nested = "\(home)/backup\(home)/old"
        let result = abbreviatedDisplayPath(nested)
        #expect(result == "~/backup\(home)/old")
        #expect(result.dropFirst().contains("~") == false)
    }

    /// A sibling directory sharing the home prefix must not be abbreviated:
    /// `/Users/alice2` is not inside `/Users/alice`.
    @Test func siblingSharingHomePrefixIsNotAbbreviated() {
        let sibling = home + "2/Documents"
        #expect(abbreviatedDisplayPath(sibling) == sibling)
    }

    @Test func trailingSlashIsStandardizedAway() {
        #expect(abbreviatedDisplayPath("\(home)/Documents/") == "~/Documents")
    }

    @Test func redundantComponentsAreStandardized() {
        #expect(abbreviatedDisplayPath("\(home)/Documents/../Documents") == "~/Documents")
    }
}
