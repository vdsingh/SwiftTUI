import Foundation

class Renderer {
    var layer: Layer

    /// Even though we only redraw invalidated parts of the screen, terminal
    /// drawing is currently still slow, as it involves moving the cursor
    /// position and printing a character there.
    /// This cache stores the screen content to see if printing is necessary.
    private var cache: [[Cell?]] = []

    /// The current cursor position, which might need to be updated before
    /// printing.
    private var currentPosition: Position = .zero

    private var currentForegroundColor: Color? = nil
    private var currentBackgroundColor: Color? = nil

    private var currentAttributes = CellAttributes()

    /// Escape sequences and characters for the frame being drawn. Emitting a
    /// frame as one write instead of a syscall per cell is what makes a
    /// full-screen repaint cheap.
    private var buffer = ""

    weak var application: Application?

    init(layer: Layer) {
        self.layer = layer
        setCache()
        setup()
    }

    /// Draw only the invalidated part of the layer.
    func update() {
        if let invalidated = layer.invalidated {
            draw(rect: invalidated)
            layer.invalidated = nil
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        writeToTerminal(buffer)
        buffer = ""
    }

    func setCache() {
        cache = .init(repeating: .init(repeating: nil, count: layer.frame.size.width.intValue), count: layer.frame.size.height.intValue)
    }

    /// Draw a specific area, or the entire layer if the area is nil.
    func draw(rect: Rect? = nil) {
        if rect == nil { layer.invalidated = nil }
        let rect = rect ?? Rect(position: .zero, size: layer.frame.size)
        guard rect.size.width > 0, rect.size.height > 0 else {
            assertionFailure("Trying to draw in empty rect")
            return
        }
        for line in rect.minLine.intValue ... rect.maxLine.intValue {
            for column in rect.minColumn.intValue ... rect.maxColumn.intValue {
                let position = Position(column: Extended(column), line: Extended(line))
                if let cell = layer.cell(at: position) {
                    drawPixel(cell, at: Position(column: Extended(column), line: Extended(line)))
                }
            }
        }
        flush()
    }

    func stop() {
        writeToTerminal(EscapeSequence.disableAlternateBuffer + EscapeSequence.showCursor)
    }

    private func drawPixel(_ cell: Cell, at position: Position) {
        guard position.column >= 0, position.line >= 0, position.column < layer.frame.size.width, position.line < layer.frame.size.height else {
            return
        }
        if cache[position.line.intValue][position.column.intValue] != cell {
            cache[position.line.intValue][position.column.intValue] = cell
            if self.currentPosition != position {
                buffer += EscapeSequence.moveTo(position)
                self.currentPosition = position
            }
            if self.currentForegroundColor != cell.foregroundColor {
                buffer += cell.foregroundColor.foregroundEscapeSequence
                self.currentForegroundColor = cell.foregroundColor
            }
            let backgroundColor = cell.backgroundColor ?? .default
            if self.currentBackgroundColor != backgroundColor {
                buffer += backgroundColor.backgroundEscapeSequence
                self.currentBackgroundColor = backgroundColor
            }
            self.updateAttributes(cell.attributes)
            buffer.append(cell.char)
            self.currentPosition.column += 1
        }
    }

    private func setup() {
        writeToTerminal(
            EscapeSequence.enableAlternateBuffer + EscapeSequence.clearScreen
                + EscapeSequence.moveTo(currentPosition) + EscapeSequence.hideCursor
        )
    }

    private func updateAttributes(_ attributes: CellAttributes) {
        if currentAttributes.bold != attributes.bold {
            buffer += attributes.bold ? EscapeSequence.enableBold : EscapeSequence.disableBold
        }
        if currentAttributes.italic != attributes.italic {
            buffer += attributes.italic ? EscapeSequence.enableItalic : EscapeSequence.disableItalic
        }
        if currentAttributes.underline != attributes.underline {
            buffer += attributes.underline ? EscapeSequence.enableUnderline : EscapeSequence.disableUnderline
        }
        if currentAttributes.strikethrough != attributes.strikethrough {
            buffer += attributes.strikethrough ? EscapeSequence.enableStrikethrough : EscapeSequence.disableStrikethrough
        }
        if currentAttributes.inverted != attributes.inverted {
            buffer += attributes.inverted ? EscapeSequence.enableInverted : EscapeSequence.disableInverted
        }
        currentAttributes = attributes
    }

}

private func writeToTerminal(_ str: String) {
    let bytes = Array(str.utf8)
    var offset = 0
    bytes.withUnsafeBufferPointer { pointer in
        while offset < pointer.count {
            let written = write(STDOUT_FILENO, pointer.baseAddress! + offset, pointer.count - offset)
            if written <= 0 { return }
            offset += written
        }
    }
}
