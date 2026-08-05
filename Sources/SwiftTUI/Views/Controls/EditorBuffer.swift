import Foundation

/// The editable text of a `TextEditor`, as lines with a cursor. Kept as a pure
/// value type so the editing logic can be unit-tested without a terminal.
///
/// Columns are counted in `Character`s, matching how the renderer draws cells.
struct EditorBuffer: Equatable {
    private(set) var lines: [String]
    private(set) var cursorLine: Int
    private(set) var cursorColumn: Int

    init(_ text: String = "") {
        lines = [""]
        cursorLine = 0
        cursorColumn = 0
        setText(text)
    }

    /// The whole document as one string, lines joined by newlines.
    var text: String { lines.joined(separator: "\n") }

    var isEmpty: Bool { lines.count == 1 && lines[0].isEmpty }

    /// Replaces all text and puts the cursor at the very end. Used when text is
    /// set from outside the editor (formatting, recalling a statement).
    mutating func setText(_ text: String) {
        lines = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        cursorLine = lines.count - 1
        cursorColumn = lines[cursorLine].count
    }

    // MARK: - Editing

    mutating func insert(_ character: Character) {
        var line = Array(lines[cursorLine])
        line.insert(character, at: min(cursorColumn, line.count))
        lines[cursorLine] = String(line)
        cursorColumn += 1
    }

    mutating func insertNewline() {
        let line = Array(lines[cursorLine])
        let split = min(cursorColumn, line.count)
        lines[cursorLine] = String(line[..<split])
        lines.insert(String(line[split...]), at: cursorLine + 1)
        cursorLine += 1
        cursorColumn = 0
    }

    /// Deletes the character before the cursor, joining lines at a line start.
    mutating func backspace() {
        if cursorColumn > 0 {
            var line = Array(lines[cursorLine])
            line.remove(at: cursorColumn - 1)
            lines[cursorLine] = String(line)
            cursorColumn -= 1
        } else if cursorLine > 0 {
            let tail = lines.remove(at: cursorLine)
            cursorLine -= 1
            cursorColumn = lines[cursorLine].count
            lines[cursorLine] += tail
        }
    }

    // MARK: - Cursor movement
    //
    // Each returns whether the cursor actually moved, so the run loop can let an
    // arrow key fall through to focus navigation at the edges of the text.

    @discardableResult mutating func moveLeft() -> Bool {
        if cursorColumn > 0 { cursorColumn -= 1; return true }
        if cursorLine > 0 { cursorLine -= 1; cursorColumn = lines[cursorLine].count; return true }
        return false
    }

    @discardableResult mutating func moveRight() -> Bool {
        if cursorColumn < lines[cursorLine].count { cursorColumn += 1; return true }
        if cursorLine < lines.count - 1 { cursorLine += 1; cursorColumn = 0; return true }
        return false
    }

    @discardableResult mutating func moveUp() -> Bool {
        guard cursorLine > 0 else { return false }
        cursorLine -= 1
        cursorColumn = min(cursorColumn, lines[cursorLine].count)
        return true
    }

    @discardableResult mutating func moveDown() -> Bool {
        guard cursorLine < lines.count - 1 else { return false }
        cursorLine += 1
        cursorColumn = min(cursorColumn, lines[cursorLine].count)
        return true
    }

    mutating func moveToLineStart() { cursorColumn = 0 }
    mutating func moveToLineEnd() { cursorColumn = lines[cursorLine].count }

    /// Puts the cursor at the given position, clamped into the text - how a
    /// mouse click lands on the nearest character it can.
    mutating func moveTo(line: Int, column: Int) {
        cursorLine = min(max(0, line), lines.count - 1)
        cursorColumn = min(max(0, column), lines[cursorLine].count)
    }

    mutating func moveToDocumentStart() { cursorLine = 0; cursorColumn = 0 }
    mutating func moveToDocumentEnd() {
        cursorLine = lines.count - 1
        cursorColumn = lines[cursorLine].count
    }

    // MARK: - Word-wise movement and deletion

    private func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    /// Moves left to the start of the current or previous word (Option/Ctrl-Left).
    @discardableResult mutating func moveWordLeft() -> Bool {
        if cursorColumn == 0 { return moveLeft() } // cross to the previous line
        let chars = Array(lines[cursorLine])
        var col = cursorColumn
        while col > 0, !isWordCharacter(chars[col - 1]) { col -= 1 }
        while col > 0, isWordCharacter(chars[col - 1]) { col -= 1 }
        cursorColumn = col
        return true
    }

    /// Moves right past the end of the current or next word (Option/Ctrl-Right).
    @discardableResult mutating func moveWordRight() -> Bool {
        let chars = Array(lines[cursorLine])
        if cursorColumn >= chars.count { return moveRight() } // cross to the next line
        var col = cursorColumn
        while col < chars.count, !isWordCharacter(chars[col]) { col += 1 }
        while col < chars.count, isWordCharacter(chars[col]) { col += 1 }
        cursorColumn = col
        return true
    }

    /// Replaces the identifier immediately before the cursor with `replacement`,
    /// leaving the cursor after it. Used to accept a completion.
    mutating func replaceCurrentWord(with replacement: String) {
        let chars = Array(lines[cursorLine])
        var start = cursorColumn
        while start > 0, isWordCharacter(chars[start - 1]) { start -= 1 }
        var updated = chars
        updated.replaceSubrange(start ..< cursorColumn, with: Array(replacement))
        lines[cursorLine] = String(updated)
        cursorColumn = start + replacement.count
    }

    /// The identifier text and everything on the current line up to the cursor,
    /// which is what completion is computed from.
    var currentLinePrefix: String { String(Array(lines[cursorLine]).prefix(cursorColumn)) }

    /// Deletes from the start of the line to the cursor (Command-Backspace,
    /// Ctrl-U). At the start of a line it deletes nothing, matching macOS text
    /// fields rather than readline's whole-line kill.
    mutating func deleteToLineStart() {
        guard cursorColumn > 0 else { return }
        let chars = Array(lines[cursorLine])
        lines[cursorLine] = String(chars[min(cursorColumn, chars.count)...])
        cursorColumn = 0
    }

    /// Deletes the character under the cursor (forward Delete), joining with the
    /// next line at a line end.
    mutating func deleteForward() {
        var chars = Array(lines[cursorLine])
        if cursorColumn < chars.count {
            chars.remove(at: cursorColumn)
            lines[cursorLine] = String(chars)
        } else if cursorLine < lines.count - 1 {
            let tail = lines.remove(at: cursorLine + 1)
            lines[cursorLine] += tail
        }
    }

    /// Deletes from the cursor back to the start of the word (Option-Backspace).
    mutating func deleteWordBackward() {
        if cursorColumn == 0 { backspace(); return } // join with the previous line
        let chars = Array(lines[cursorLine])
        var col = cursorColumn
        while col > 0, !isWordCharacter(chars[col - 1]) { col -= 1 }
        while col > 0, isWordCharacter(chars[col - 1]) { col -= 1 }
        var updated = chars
        updated.removeSubrange(col ..< cursorColumn)
        lines[cursorLine] = String(updated)
        cursorColumn = col
    }
}
