import Foundation

/// A handle on a `TextEditor`'s text that surrounding code can read and set.
///
/// The editor owns its buffer and writes into `text` as the user types, so
/// reading is a plain property access with no per-keystroke view rebuild. Call
/// `set(_:)` to push new text into the editor - used to format the query or to
/// recall a previous statement.
public final class EditorDocument {
    public var text: String
    /// Wired by the editor control so `set(_:)` can reload the on-screen buffer.
    var apply: ((String) -> Void)?

    public init(text: String = "") {
        self.text = text
    }

    public func set(_ newText: String) {
        text = newText
        apply?(newText)
    }
}

/// A multi-line, editable text area with a movable cursor. Arrow keys move the
/// cursor (falling through to focus navigation at the edges), Return inserts a
/// newline, and Control-R runs the `onRun` action. Ctrl-A / Ctrl-E jump to the
/// start / end of the line.
public struct TextEditor: View, PrimitiveView {
    let document: EditorDocument
    let placeholder: String?
    let onRun: () -> Void

    @Environment(\.placeholderColor) private var placeholderColor: Color

    public init(document: EditorDocument, placeholder: String? = nil, onRun: @escaping () -> Void = {}) {
        self.document = document
        self.placeholder = placeholder
        self.onRun = onRun
    }

    static var size: Int? { 1 }

    func buildNode(_ node: Node) {
        setupEnvironmentProperties(node: node)
        node.control = TextEditorControl(
            document: document,
            placeholder: placeholder ?? "",
            placeholderColor: placeholderColor,
            onRun: onRun
        )
    }

    func updateNode(_ node: Node) {
        setupEnvironmentProperties(node: node)
        node.view = self
        let control = node.control as! TextEditorControl
        control.onRun = onRun
        control.placeholderColor = placeholderColor
    }

    private class TextEditorControl: Control {
        let document: EditorDocument
        var buffer: EditorBuffer
        var placeholder: String
        var placeholderColor: Color
        var onRun: () -> Void

        private var scrollTop = 0
        private var scrollLeft = 0

        init(document: EditorDocument, placeholder: String, placeholderColor: Color, onRun: @escaping () -> Void) {
            self.document = document
            self.buffer = EditorBuffer(document.text)
            self.placeholder = placeholder
            self.placeholderColor = placeholderColor
            self.onRun = onRun
            super.init()
            document.apply = { [weak self] text in
                guard let self else { return }
                self.buffer.setText(text)
                self.refresh()
            }
        }

        override var selectable: Bool { true }
        override var handlesArrowKeys: Bool { true }

        override func size(proposedSize: Size) -> Size { proposedSize }

        override func layout(size: Size) {
            super.layout(size: size)
            ensureCursorVisible()
        }

        override func becomeFirstResponder() {
            super.becomeFirstResponder()
            layer.invalidate()
        }

        override func resignFirstResponder() {
            super.resignFirstResponder()
            layer.invalidate()
        }

        override func handleArrowKey(_ direction: ArrowKeyDirection) -> Bool {
            let moved: Bool
            switch direction {
            case .up: moved = buffer.moveUp()
            case .down: moved = buffer.moveDown()
            case .left: moved = buffer.moveLeft()
            case .right: moved = buffer.moveRight()
            }
            if moved { refresh() }
            return moved
        }

        override func handleKeyCommand(_ command: KeyCommand) -> Bool {
            switch command {
            case .wordLeft: buffer.moveWordLeft(); refresh()
            case .wordRight: buffer.moveWordRight(); refresh()
            case .lineStart: buffer.moveToLineStart(); refresh()
            case .lineEnd: buffer.moveToLineEnd(); refresh()
            case .documentStart: buffer.moveToDocumentStart(); refresh()
            case .documentEnd: buffer.moveToDocumentEnd(); refresh()
            case .deleteWordBackward: buffer.deleteWordBackward(); commit()
            }
            return true
        }

        override func handleEvent(_ char: Character) {
            switch char {
            case "\u{12}": // Ctrl-R
                onRun()
            case "\u{01}": // Ctrl-A: start of line
                buffer.moveToLineStart(); refresh()
            case "\u{05}": // Ctrl-E: end of line
                buffer.moveToLineEnd(); refresh()
            case "\n", "\r":
                buffer.insertNewline(); commit()
            case ASCII.DEL, "\u{08}": // Delete / Backspace
                buffer.backspace(); commit()
            default:
                if let ascii = char.asciiValue, ascii < 0x20 { return } // ignore other controls
                buffer.insert(char); commit()
            }
        }

        /// After an edit: publish the text so `onRun`/formatting see it, then repaint.
        private func commit() {
            document.text = buffer.text
            refresh()
        }

        /// After a cursor move or external set: keep the cursor on screen and repaint.
        private func refresh() {
            ensureCursorVisible()
            layer.invalidate()
        }

        private func ensureCursorVisible() {
            let height = max(1, layer.frame.size.height.intValue)
            let width = max(1, layer.frame.size.width.intValue)
            if buffer.cursorLine < scrollTop {
                scrollTop = buffer.cursorLine
            } else if buffer.cursorLine >= scrollTop + height {
                scrollTop = buffer.cursorLine - height + 1
            }
            if buffer.cursorColumn < scrollLeft {
                scrollLeft = buffer.cursorColumn
            } else if buffer.cursorColumn >= scrollLeft + width {
                scrollLeft = buffer.cursorColumn - width + 1
            }
            scrollTop = max(0, scrollTop)
            scrollLeft = max(0, scrollLeft)
        }

        override func cell(at position: Position) -> Cell? {
            // Placeholder over an empty, unfocused editor.
            if buffer.isEmpty, !isFirstResponder {
                guard position.line.intValue == 0 else { return Cell(char: " ") }
                let index = position.column.intValue
                if index < placeholder.count {
                    let character = placeholder[placeholder.index(placeholder.startIndex, offsetBy: index)]
                    return Cell(char: character, foregroundColor: placeholderColor)
                }
                return Cell(char: " ")
            }

            let row = position.line.intValue + scrollTop
            let column = position.column.intValue + scrollLeft
            guard row >= 0, row < buffer.lines.count else { return Cell(char: " ") }
            let characters = Array(buffer.lines[row])
            let onCursor = isFirstResponder && row == buffer.cursorLine && column == buffer.cursorColumn
            if column >= 0, column < characters.count {
                return Cell(char: characters[column], attributes: CellAttributes(underline: onCursor))
            }
            return Cell(char: " ", attributes: CellAttributes(underline: onCursor))
        }
    }
}
