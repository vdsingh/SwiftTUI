import Foundation

/// Parses xterm SGR mouse reports (private mode 1006): `ESC [ < b ; x ; y (M|m)`.
///
/// The run loop recognises the `ESC [ <` prefix and then feeds the remaining
/// characters here: the numeric body and the terminating `M` (press) or `m`
/// (release). SGR encoding is used rather than the legacy X10 encoding because
/// it is unambiguous for terminals wider or taller than 223 cells.
struct MouseParser {
    enum Event: Equatable {
        /// A left-button press, in the terminal's own 1-based cell coordinates.
        case leftClick(column: Int, line: Int)
        case scrollUp
        case scrollDown
    }

    enum Step: Equatable {
        /// Mid-sequence: more characters are needed.
        case consuming
        /// A complete, actionable event.
        case event(Event)
        /// A complete report we deliberately ignore (release, drag, other buttons).
        case ignored
        /// Not a well-formed report; the sequence should be abandoned.
        case invalid
    }

    private var body = ""

    mutating func parse(_ char: Character) -> Step {
        if char == "M" || char == "m" {
            let step = decode(released: char == "m")
            body = ""
            return step
        }
        guard char.isNumber || char == ";" else {
            body = ""
            return .invalid
        }
        body.append(char)
        return .consuming
    }

    private func decode(released: Bool) -> Step {
        let parts = body.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let code = Int(parts[0]),
              let column = Int(parts[1]),
              let line = Int(parts[2])
        else {
            return .invalid
        }

        // Bit 6 (64) marks a wheel event; its low bit selects the direction.
        if code & 0b100_0000 != 0 {
            guard !released else { return .ignored }
            return .event(code & 1 == 0 ? .scrollUp : .scrollDown)
        }

        // Bit 5 (32) marks motion (a drag); only a clean left press acts.
        let isMotion = code & 0b10_0000 != 0
        let button = code & 0b11
        if !isMotion && !released && button == 0 {
            return .event(.leftClick(column: column, line: line))
        }
        return .ignored
    }
}
