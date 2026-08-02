import XCTest
@testable import SwiftTUI

final class MouseParserTests: XCTestCase {
    /// Feeds the characters that follow the `ESC [ <` prefix and returns the last
    /// step, the way `Application` drives the parser.
    private func feed(_ body: String) -> MouseParser.Step {
        var parser = MouseParser()
        var last: MouseParser.Step = .consuming
        for char in body {
            last = parser.parse(char)
        }
        return last
    }

    func testLeftPressReportsAOneBasedClick() {
        XCTAssertEqual(feed("0;12;5M"), .event(.leftClick(column: 12, line: 5)))
    }

    func testLeftReleaseIsIgnored() {
        // Same coordinates, lowercase terminator: a button release, not a click.
        XCTAssertEqual(feed("0;12;5m"), .ignored)
    }

    func testWheelUpAndDown() {
        XCTAssertEqual(feed("64;3;3M"), .event(.scrollUp))
        XCTAssertEqual(feed("65;3;3M"), .event(.scrollDown))
    }

    func testDragIsIgnored() {
        // Bit 5 (32) set with the left button held marks motion.
        XCTAssertEqual(feed("32;4;4M"), .ignored)
    }

    func testRightAndMiddleButtonsAreIgnored() {
        XCTAssertEqual(feed("2;4;4M"), .ignored) // right press
        XCTAssertEqual(feed("1;4;4M"), .ignored) // middle press
    }

    func testMalformedBodyIsInvalid() {
        XCTAssertEqual(feed("0;12M"), .invalid)          // too few fields
        XCTAssertEqual(feed("0;1x2;5M"), .invalid)       // stray character aborts
    }

    func testMidSequenceKeepsConsuming() {
        var parser = MouseParser()
        XCTAssertEqual(parser.parse("0"), .consuming)
        XCTAssertEqual(parser.parse(";"), .consuming)
        XCTAssertEqual(parser.parse("7"), .consuming)
        XCTAssertEqual(parser.parse(";"), .consuming)
        XCTAssertEqual(parser.parse("9"), .consuming)
        XCTAssertEqual(parser.parse("M"), .event(.leftClick(column: 7, line: 9)))
    }

    func testParserResetsBetweenReports() {
        var parser = MouseParser()
        _ = "0;1;1M".map { parser.parse($0) }
        // A second report reusing the same parser must not see stale digits.
        var last: MouseParser.Step = .consuming
        for char in "65;2;2M" { last = parser.parse(char) }
        XCTAssertEqual(last, .event(.scrollDown))
    }
}
