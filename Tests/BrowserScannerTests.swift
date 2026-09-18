import XCTest
@testable import DuoTranslator

final class BrowserScannerTests: XCTestCase {
    private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private let brave = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"

    func testDetectedReturnsOnlyInstalled() {
        let found = BrowserScanner.detected { $0 == self.chrome || $0 == self.brave }
        XCTAssertEqual(Set(found.map(\.path)), [chrome, brave])
        XCTAssertTrue(found.contains { $0.name == "Google Chrome" })
    }

    func testDetectedEmptyWhenNoneInstalled() {
        XCTAssertTrue(BrowserScanner.detected { _ in false }.isEmpty)
    }

    func testResolvePrefersSavedChoiceWhenPresent() {
        let path = BrowserScanner.resolve(preferred: brave) { $0 == self.brave || $0 == self.chrome }
        XCTAssertEqual(path, brave)
    }

    func testResolveFallsBackToFirstDetectedWhenPreferredMissing() {
        // Preferred path no longer exists → first detected (Chrome ranks first).
        let path = BrowserScanner.resolve(preferred: "/Applications/Gone.app/x") { $0 == self.chrome }
        XCTAssertEqual(path, chrome)
    }

    func testResolveFallsBackWhenPreferredEmpty() {
        let path = BrowserScanner.resolve(preferred: "") { $0 == self.chrome }
        XCTAssertEqual(path, chrome)
    }

    func testResolveNilWhenNoneAvailable() {
        XCTAssertNil(BrowserScanner.resolve(preferred: "") { _ in false })
    }
}
