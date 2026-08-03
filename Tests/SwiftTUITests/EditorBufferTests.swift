import XCTest
@testable import SwiftTUI

final class EditorBufferTests: XCTestCase {
    func testInitPutsCursorAtTheEnd() {
        let buffer = EditorBuffer("select 1")
        XCTAssertEqual(buffer.lines, ["select 1"])
        XCTAssertEqual(buffer.cursorLine, 0)
        XCTAssertEqual(buffer.cursorColumn, 8)
    }

    func testInitFromMultilineText() {
        let buffer = EditorBuffer("select *\nfrom t")
        XCTAssertEqual(buffer.lines, ["select *", "from t"])
        XCTAssertEqual(buffer.cursorLine, 1)
        XCTAssertEqual(buffer.cursorColumn, 6)
    }

    func testInsertAndText() {
        var buffer = EditorBuffer("ab")
        buffer.moveLeft()            // between a and b
        buffer.insert("X")
        XCTAssertEqual(buffer.text, "aXb")
        XCTAssertEqual(buffer.cursorColumn, 2)
    }

    func testNewlineSplitsTheLine() {
        var buffer = EditorBuffer("select from")
        for _ in 0..<5 { buffer.moveLeft() } // cursor after "select"
        buffer.insertNewline()
        XCTAssertEqual(buffer.lines, ["select", " from"])
        XCTAssertEqual(buffer.cursorLine, 1)
        XCTAssertEqual(buffer.cursorColumn, 0)
    }

    func testBackspaceWithinLine() {
        var buffer = EditorBuffer("abc")
        buffer.backspace()
        XCTAssertEqual(buffer.text, "ab")
        XCTAssertEqual(buffer.cursorColumn, 2)
    }

    func testBackspaceAtLineStartJoinsLines() {
        var buffer = EditorBuffer("ab\ncd")
        buffer.moveToLineStart()     // start of "cd"
        buffer.backspace()
        XCTAssertEqual(buffer.lines, ["abcd"])
        XCTAssertEqual(buffer.cursorLine, 0)
        XCTAssertEqual(buffer.cursorColumn, 2)
    }

    func testMovementReturnsWhetherItMovedAtBoundaries() {
        var buffer = EditorBuffer("a\nbb")
        // cursor at end of "bb"
        XCTAssertFalse(buffer.moveRight())      // already at the very end
        XCTAssertFalse(buffer.moveDown())       // already on the last line
        XCTAssertTrue(buffer.moveUp())          // to line 0
        XCTAssertEqual(buffer.cursorColumn, 1)  // clamped to "a".count
        buffer.moveToLineStart()
        XCTAssertFalse(buffer.moveLeft())       // at the very start
        XCTAssertFalse(buffer.moveUp())
    }

    func testSetTextReplacesEverything() {
        var buffer = EditorBuffer("old")
        buffer.setText("new\ntext")
        XCTAssertEqual(buffer.lines, ["new", "text"])
        XCTAssertEqual(buffer.cursorLine, 1)
        XCTAssertEqual(buffer.cursorColumn, 4)
    }

    func testEmpty() {
        XCTAssertTrue(EditorBuffer("").isEmpty)
        XCTAssertFalse(EditorBuffer("x").isEmpty)
    }
}
