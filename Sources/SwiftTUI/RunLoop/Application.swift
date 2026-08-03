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
    private enum InputState { case ground, escape, csi, mouse }
    private var inputState: InputState = .ground
    private var mouseParser = MouseParser()

    private enum ArrowDirection { case up, down, left, right }

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
                if char == "[" {
                    inputState = .csi
                } else {
                    // A bare escape, or a sequence we don't recognise: treat the
                    // following character as ordinary input, as before.
                    inputState = .ground
                    handleKey(char)
                }
            case .csi:
                switch char {
                case "A": moveFocus(.up); inputState = .ground
                case "B": moveFocus(.down); inputState = .ground
                case "C": moveFocus(.right); inputState = .ground
                case "D": moveFocus(.left); inputState = .ground
                case "<": inputState = .mouse
                default: inputState = .ground
                }
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
        if char == ASCII.EOT {
            stop()
        } else {
            window.firstResponder?.handleEvent(char)
        }
    }

    private func moveFocus(_ direction: ArrowDirection) {
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
