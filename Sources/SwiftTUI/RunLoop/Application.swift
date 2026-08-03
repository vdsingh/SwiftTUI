import Foundation
#if os(macOS)
import AppKit
#endif

public class Application {
    private let node: Node
    private let window: Window
    private let control: Control
    private let renderer: Renderer

    private let runLoopType: RunLoopType

    /// Where in an escape sequence the input reader currently is. Kept across
    /// reads because a sequence can straddle two `availableData` chunks.
    private enum InputState { case ground, escape, csi, ss3, mouse }
    private var inputState: InputState = .ground
    private var csiBuffer = ""
    private var mouseParser = MouseParser()

    /// An app-level hook that sees each ordinary key before it reaches the focused
    /// control. Return true to consume it. swsql uses this to run the query on
    /// Ctrl-R from anywhere, not only while the editor is focused.
    public var keyHandler: ((Character) -> Bool)?

    private var invalidatedNodes: [Node] = []
    private var updateScheduled = false

    public init<I: View>(rootView: I, runLoopType: RunLoopType = .dispatch) {
        self.runLoopType = runLoopType

        node = Node(view: VStack(content: rootView).view)
        node.build()

        control = node.control!

        window = Window()
        window.addControl(control)

        window.firstResponder = control.firstSelectableElement
        window.firstResponder?.becomeFirstResponder()

        renderer = Renderer(layer: window.layer)
        window.layer.renderer = renderer

        node.application = self
        renderer.application = self
    }

    var stdInSource: DispatchSourceRead?

    public enum RunLoopType {
        /// The default option, using Dispatch for the main run loop.
        case dispatch

        #if os(macOS)
        /// This creates and runs an NSApplication with an associated run loop. This allows you
        /// e.g. to open NSWindows running simultaneously to the terminal app. This requires macOS
        /// and AppKit.
        case cocoa
        #endif
    }

    public func start() {
        setInputMode()
        updateWindowSize()
        control.layout(size: window.layer.frame.size)
        renderer.draw()

        let stdInSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        stdInSource.setEventHandler(qos: .default, flags: [], handler: self.handleInput)
        stdInSource.resume()
        self.stdInSource = stdInSource

        let sigWinChSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        sigWinChSource.setEventHandler(qos: .default, flags: [], handler: self.handleWindowSizeChange)
        sigWinChSource.resume()

        signal(SIGINT, SIG_IGN)
        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigIntSource.setEventHandler(qos: .default, flags: [], handler: self.stop)
        sigIntSource.resume()

        switch runLoopType {
        case .dispatch:
            dispatchMain()
        #if os(macOS)
        case .cocoa:
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        #endif
        }
    }

    private func setInputMode() {
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr);
        // Ask the terminal to report mouse clicks and wheel events, encoded with
        // SGR (1006) so coordinates stay correct past column/row 223.
        writeToTerminal("\u{1b}[?1000h\u{1b}[?1006h")
    }

    private func writeToTerminal(_ string: String) {
        FileHandle.standardOutput.write(Data(string.utf8))
    }

    private func handleInput() {
        let data = FileHandle.standardInput.availableData

        guard let string = String(data: data, encoding: .utf8) else {
            return
        }

        for char in string {
            switch inputState {
            case .ground:
                if char == "\u{1b}" {
                    inputState = .escape
                } else {
                    handleKey(char)
                }
            case .escape:
                switch char {
                case "[": inputState = .csi; csiBuffer = ""
                case "O": inputState = .ss3
                default:
                    // ESC followed by a character is a Meta/Alt combination.
                    inputState = .ground
                    handleMeta(char)
                }
            case .csi:
                if char == "<", csiBuffer.isEmpty {
                    inputState = .mouse // SGR mouse report: ESC [ < …
                } else if char.isNumber || char == ";" {
                    csiBuffer.append(char)
                } else {
                    dispatchCSI(parameters: csiBuffer, final: char)
                    inputState = .ground
                }
            case .ss3:
                dispatchSS3(char)
                inputState = .ground
            case .mouse:
                switch mouseParser.parse(char) {
                case .consuming:
                    break
                case .event(let event):
                    handleMouse(event)
                    inputState = .ground
                case .ignored, .invalid:
                    inputState = .ground
                }
            }
        }
    }

    private func handleKey(_ char: Character) {
        if let keyHandler, keyHandler(char) { return }
        switch char {
        case ASCII.EOT:
            stop()
        case "\u{17}": // Ctrl-W: delete the previous word
            deliverCommand(.deleteWordBackward)
        default:
            window.firstResponder?.handleEvent(char)
        }
    }

    /// ESC-prefixed (Meta/Alt) keys: word movement and word delete.
    private func handleMeta(_ char: Character) {
        switch char {
        case "b", "B": deliverCommand(.wordLeft)
        case "f", "F": deliverCommand(.wordRight)
        case ASCII.DEL, "\u{08}": deliverCommand(.deleteWordBackward)
        default: window.firstResponder?.handleEvent(char)
        }
    }

    /// SS3 sequences (ESC O …): arrows in application mode, and Home/End.
    private func dispatchSS3(_ char: Character) {
        switch char {
        case "A": deliverArrow(.up)
        case "B": deliverArrow(.down)
        case "C": deliverArrow(.right)
        case "D": deliverArrow(.left)
        case "H": deliverCommand(.lineStart)
        case "F": deliverCommand(.lineEnd)
        default: break
        }
    }

    /// A complete CSI sequence: `parameters` are the digits/semicolons between
    /// `ESC [` and the final byte. Handles arrows (plain and modified), Home/End,
    /// and the `~`-terminated Home/End/Delete forms across terminals.
    private func dispatchCSI(parameters: String, final: Character) {
        let fields = parameters.split(separator: ";").map { Int($0) ?? 0 }
        let modifier = fields.count >= 2 ? fields[1] : 1
        // xterm modifier encoding: value - 1 is a bitmask (1 Shift, 2 Alt, 4 Ctrl, 8 Meta).
        let mask = max(0, modifier - 1)
        let alt = mask & 2 != 0
        let ctrl = mask & 4 != 0
        let meta = mask & 8 != 0
        let word = alt || ctrl   // Option or Control moves by word
        let line = meta          // Command (remapped) or explicit Meta moves by line

        switch final {
        case "A": meta ? deliverCommand(.documentStart) : deliverArrow(.up)
        case "B": meta ? deliverCommand(.documentEnd) : deliverArrow(.down)
        case "C":
            if line { deliverCommand(.lineEnd) }
            else if word { deliverCommand(.wordRight) }
            else { deliverArrow(.right) }
        case "D":
            if line { deliverCommand(.lineStart) }
            else if word { deliverCommand(.wordLeft) }
            else { deliverArrow(.left) }
        case "H": deliverCommand(ctrl ? .documentStart : .lineStart)   // Home / Ctrl-Home
        case "F": deliverCommand(ctrl ? .documentEnd : .lineEnd)       // End / Ctrl-End
        case "~":
            switch fields.first ?? 0 {
            case 1, 7: deliverCommand(.lineStart)   // Home
            case 4, 8: deliverCommand(.lineEnd)     // End
            default: break                          // e.g. 3 = forward Delete (unsupported)
            }
        default: break
        }
    }

    private func deliverCommand(_ command: KeyCommand) {
        _ = window.firstResponder?.handleKeyCommand(command)
    }

    /// Sends an arrow key to the focused control if it consumes arrows (a text
    /// editor moving its cursor); otherwise, or when that control declines the key
    /// at a boundary, moves focus.
    private func deliverArrow(_ direction: ArrowKeyDirection) {
        if let responder = window.firstResponder, responder.handlesArrowKeys,
           responder.handleArrowKey(direction) {
            return
        }
        moveFocus(direction)
    }

    private func moveFocus(_ direction: ArrowKeyDirection) {
        let next: Control?
        switch direction {
        case .up: next = window.firstResponder?.selectableElement(above: 0)
        case .down: next = window.firstResponder?.selectableElement(below: 0)
        case .right: next = window.firstResponder?.selectableElement(rightOf: 0)
        case .left: next = window.firstResponder?.selectableElement(leftOf: 0)
        }
        guard let next else { return }
        window.firstResponder?.resignFirstResponder()
        window.firstResponder = next
        window.firstResponder?.becomeFirstResponder()
    }

    private func handleMouse(_ event: MouseParser.Event) {
        switch event {
        case .leftClick(let column, let line):
            // The terminal reports 1-based cells; the control tree is 0-based.
            let point = Position(column: Extended(column - 1), line: Extended(line - 1))
            guard let target = control.control(at: point) else { return }
            // A clickable-but-not-selectable control (e.g. `.onClick`) fires its
            // action without taking focus, so it never disturbs keyboard navigation.
            if target.selectable, window.firstResponder !== target {
                window.firstResponder?.resignFirstResponder()
                window.firstResponder = target
                target.becomeFirstResponder()
            }
            target.activateByClick()
        case .scrollUp:
            moveFocus(.up)
        case .scrollDown:
            moveFocus(.down)
        }
    }

    func invalidateNode(_ node: Node) {
        invalidatedNodes.append(node)
        scheduleUpdate()
    }

    func scheduleUpdate() {
        if !updateScheduled {
            DispatchQueue.main.async { self.update() }
            updateScheduled = true
        }
    }

    private func update() {
        updateScheduled = false

        for node in invalidatedNodes {
            node.update(using: node.view)
        }
        invalidatedNodes = []

        control.layout(size: window.layer.frame.size)
        renderer.update()
    }

    private func handleWindowSizeChange() {
        updateWindowSize()
        control.layer.invalidate()
        update()
    }

    private func updateWindowSize() {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0,
              size.ws_col > 0, size.ws_row > 0 else {
            assertionFailure("Could not get window size")
            return
        }
        window.layer.frame.size = Size(width: Extended(Int(size.ws_col)), height: Extended(Int(size.ws_row)))
        renderer.setCache()
    }

    private func stop() {
        renderer.stop()
        resetInputMode() // Fix for: https://github.com/rensbreur/SwiftTUI/issues/25
        exit(0)
    }

    /// Fix for: https://github.com/rensbreur/SwiftTUI/issues/25
    private func resetInputMode() {
        // Stop the terminal reporting mouse events, so the shell that regains the
        // terminal is not fed escape sequences on every click.
        writeToTerminal("\u{1b}[?1006l\u{1b}[?1000l")
        // Reset ECHO and ICANON values:
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag |= tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr);
    }

}
