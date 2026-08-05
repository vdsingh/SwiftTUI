import Foundation

public struct TextField: View, PrimitiveView {
    public let placeholder: String?
    public let action: (String) -> Void

    @Environment(\.placeholderColor) private var placeholderColor: Color

    public init(placeholder: String? = nil, action: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.action = action
    }

    static var size: Int? { 1 }

    func buildNode(_ node: Node) {
        setupEnvironmentProperties(node: node)
        node.control = TextFieldControl(placeholder: placeholder ?? "", placeholderColor: placeholderColor, action: action)
    }

    func updateNode(_ node: Node) {
        setupEnvironmentProperties(node: node)
        node.view = self
        (node.control as! TextFieldControl).action = action
    }

    private class TextFieldControl: Control {
        var placeholder: String
        var placeholderColor: Color
        var action: (String) -> Void

        /// A single-line editor buffer, so the field shares the editor's cursor,
        /// word and line movement, and deletion behaviour.
        private var buffer = EditorBuffer()
        /// The first visible column when the text outgrows the field, kept so
        /// the cursor always stays on screen.
        private var scrollLeft = 0

        var text: String { buffer.text }

        init(placeholder: String, placeholderColor: Color, action: @escaping (String) -> Void) {
            self.placeholder = placeholder
            self.placeholderColor = placeholderColor
            self.action = action
        }

        override func size(proposedSize: Size) -> Size {
            // Fill the width the container proposes (a `.frame(width:)` proposes
            // its fixed width), so cursor scrolling is computed against the box
            // the user actually sees; fall back to the text's natural width when
            // the proposal is unbounded.
            let natural = Extended(max(text.count, placeholder.count)) + 1
            let width = proposedSize.width == .infinity ? natural : proposedSize.width
            return Size(width: width, height: 1)
        }

        override func layout(size: Size) {
            super.layout(size: size)
            ensureCursorVisible()
        }

        override func handleEvent(_ char: Character) {
            switch char {
            case "\n", "\r":
                let submitted = buffer.text
                buffer = EditorBuffer()
                scrollLeft = 0
                layer.invalidate()
                action(submitted)
            case ASCII.DEL, "\u{08}": // Delete / Backspace
                buffer.backspace(); refresh()
            case "\u{01}": // Ctrl-A: start of the text
                buffer.moveToLineStart(); refresh()
            case "\u{05}": // Ctrl-E: end of the text
                buffer.moveToLineEnd(); refresh()
            default:
                if let ascii = char.asciiValue, ascii < 0x20 { return } // other controls
                buffer.insert(char); refresh()
            }
        }

        override var handlesArrowKeys: Bool { true }

        /// Left and right move the cursor, falling through to focus navigation
        /// at the ends of the text. Up and down always fall through: the field
        /// is one line, so they mean "the control above / below".
        override func handleArrowKey(_ direction: ArrowKeyDirection) -> Bool {
            let moved: Bool
            switch direction {
            case .left: moved = buffer.moveLeft()
            case .right: moved = buffer.moveRight()
            case .up, .down: moved = false
            }
            if moved { refresh() }
            return moved
        }

        override func handleKeyCommand(_ command: KeyCommand) -> Bool {
            switch command {
            case .wordLeft: buffer.moveWordLeft()
            case .wordRight: buffer.moveWordRight()
            case .lineStart, .documentStart: buffer.moveToLineStart()
            case .lineEnd, .documentEnd: buffer.moveToLineEnd()
            case .deleteWordBackward: buffer.deleteWordBackward()
            case .deleteToLineStart: buffer.deleteToLineStart()
            case .deleteForward: buffer.deleteForward()
            }
            refresh()
            return true
        }

        override func activateByClick(at point: Position) {
            buffer.moveTo(line: 0, column: point.column.intValue + scrollLeft)
            refresh()
        }

        private func refresh() {
            ensureCursorVisible()
            layer.invalidate()
        }

        private func ensureCursorVisible() {
            let width = max(1, layer.frame.size.width.intValue)
            if buffer.cursorColumn < scrollLeft {
                scrollLeft = buffer.cursorColumn
            } else if buffer.cursorColumn >= scrollLeft + width {
                scrollLeft = buffer.cursorColumn - width + 1
            }
            scrollLeft = max(0, scrollLeft)
        }

        override func cell(at position: Position) -> Cell? {
            guard position.line == 0 else { return nil }
            if buffer.isEmpty {
                if position.column.intValue < placeholder.count {
                    let showUnderline = (position.column.intValue == 0) && isFirstResponder
                    let char = placeholder[placeholder.index(placeholder.startIndex, offsetBy: position.column.intValue)]
                    return Cell(
                        char: char,
                        foregroundColor: placeholderColor,
                        attributes: CellAttributes(underline: showUnderline)
                    )
                }
                return .init(char: " ")
            }
            let characters = Array(buffer.lines[0])
            let index = position.column.intValue + scrollLeft
            let onCursor = isFirstResponder && index == buffer.cursorColumn
            guard index >= 0, index < characters.count else {
                return Cell(char: " ", attributes: CellAttributes(underline: onCursor))
            }
            return Cell(char: characters[index], attributes: CellAttributes(underline: onCursor))
        }

        override var selectable: Bool { true }

        override func becomeFirstResponder() {
            super.becomeFirstResponder()
            layer.invalidate()
        }

        override func resignFirstResponder() {
            super.resignFirstResponder()
            layer.invalidate()
        }
    }
}

extension EnvironmentValues {
    public var placeholderColor: Color {
        get { self[PlaceholderColorEnvironmentKey.self] }
        set { self[PlaceholderColorEnvironmentKey.self] = newValue }
    }
}

private struct PlaceholderColorEnvironmentKey: EnvironmentKey {
    static var defaultValue: Color { .default }
}
