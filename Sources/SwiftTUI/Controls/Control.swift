import Foundation

/// The basic layout object that can be created by a node. Not every node will
/// create a control (e.g. ForEach won't).
class Control: LayerDrawing {
    private(set) var children: [Control] = []
    private(set) var parent: Control?

    private var index: Int = 0

    var window: Window?
    private(set) lazy var layer: Layer = makeLayer()

    var root: Control { parent?.root ?? self }

    func addSubview(_ view: Control, at index: Int) {
        self.children.insert(view, at: index)
        layer.addLayer(view.layer, at: index)
        view.parent = self
        view.window = window
        for i in index ..< children.count {
            children[i].index = i
        }
        if let window = root.window, window.firstResponder == nil {
            if let responder = view.firstSelectableElement {
                window.firstResponder = responder
                responder.becomeFirstResponder()
            }
        }
    }

    func removeSubview(at index: Int) {
        if children[index].isFirstResponder || root.window?.firstResponder?.isDescendant(of: children[index]) == true {
            root.window?.firstResponder?.resignFirstResponder()
            root.window?.firstResponder = selectableElement(above: index) ?? selectableElement(below: index)
            root.window?.firstResponder?.becomeFirstResponder()
        }
        children[index].window = nil
        children[index].parent = nil
        self.children.remove(at: index)
        layer.removeLayer(at: index)
        for i in index ..< children.count {
            children[i].index = i
        }
    }

    func isDescendant(of control: Control) -> Bool {
        guard let parent else { return false }
        return control === parent || parent.isDescendant(of: control)
    }

    func makeLayer() -> Layer {
        let layer = Layer()
        layer.content = self
        return layer
    }

    // MARK: - Layout

    func size(proposedSize: Size) -> Size {
        proposedSize
    }

    func layout(size: Size) {
        layer.frame.size = size
    }

    func horizontalFlexibility(height: Extended) -> Extended {
        let minSize = size(proposedSize: Size(width: 0, height: height))
        let maxSize = size(proposedSize: Size(width: .infinity, height: height))
        return maxSize.width - minSize.width
    }

    func verticalFlexibility(width: Extended) -> Extended {
        let minSize = size(proposedSize: Size(width: width, height: 0))
        let maxSize = size(proposedSize: Size(width: width, height: .infinity))
        return maxSize.height - minSize.height
    }

    // MARK: - Drawing

    func cell(at position: Position) -> Cell? { nil }

    // MARK: - Event handling

    func handleEvent(_ char: Character) {
        for subview in children {
            subview.handleEvent(char)
        }
    }

    func becomeFirstResponder() {
        scroll(to: .zero)
    }

    func resignFirstResponder() {}

    var isFirstResponder: Bool { root.window?.firstResponder === self }

    // MARK: - Selection

    var selectable: Bool { false }

    final var firstSelectableElement: Control? {
        if selectable { return self }
        for control in children {
            if let element = control.firstSelectableElement { return element }
        }
        return nil
    }

    func selectableElement(below index: Int) -> Control? { parent?.selectableElement(below: self.index) }
    func selectableElement(above index: Int) -> Control? { parent?.selectableElement(above: self.index) }
    func selectableElement(rightOf index: Int) -> Control? { parent?.selectableElement(rightOf: self.index) }
    func selectableElement(leftOf index: Int) -> Control? { parent?.selectableElement(leftOf: self.index) }

    // MARK: - Hit testing

    /// Whether a mouse click can land on this control. Defaults to `selectable`,
    /// so keyboard-navigable controls are also clickable. A control can be
    /// clickable without being selectable (see `.onClick`): it responds to a click
    /// but is skipped by keyboard focus, which suits header and toolbar affordances
    /// that should not join the tab order or take the initial focus.
    var clickable: Bool { selectable }

    /// The deepest clickable control containing `point`, which is expressed in
    /// this control's own coordinate space, along with the point translated into
    /// the hit control's space (so a text field can put its cursor under the
    /// click). This mirrors how `Layer.cell(at:)` walks the tree to draw, so a
    /// click resolves to the same control the user sees under the cursor. The
    /// last child is visited first because it is drawn on top, matching the
    /// renderer when controls overlap.
    func control(at point: Position) -> (control: Control, point: Position)? {
        for child in children.reversed() {
            guard child.layer.frame.contains(point) else { continue }
            if let hit = child.control(at: point - child.layer.frame.position) {
                return hit
            }
        }
        return clickable ? (self, point) : nil
    }

    /// The deepest control containing `point`, clickable or not: the starting
    /// point for events that bubble up to whichever ancestor wants them.
    func control(containing point: Position) -> Control {
        for child in children.reversed() {
            guard child.layer.frame.contains(point) else { continue }
            return child.control(containing: point - child.layer.frame.position)
        }
        return self
    }

    // MARK: - Mouse activation

    /// Performs this control's primary action after it is clicked, with `point`
    /// in this control's own coordinate space. The default does nothing, so
    /// clicking a text field only places focus; controls with an action, such as
    /// buttons, override this, and text controls use `point` to put the cursor
    /// where the click landed. Keeping it separate from `handleEvent` means a
    /// click never submits a field the way return would.
    func activateByClick(at point: Position) {}

    /// Called when the mouse wheel scrolls sideways with the pointer over this
    /// control; `delta` is -1 for a leftward tick and +1 for a rightward one.
    /// The default bubbles to the parent, so the nearest interested ancestor of
    /// the control under the pointer handles it. Returning false leaves the
    /// event unclaimed, and it is dropped.
    func handleHorizontalScroll(_ delta: Int) -> Bool {
        parent?.handleHorizontalScroll(delta) ?? false
    }

    // MARK: - Arrow keys

    /// Whether this control consumes arrow keys itself - a text editor moving its
    /// cursor - instead of letting them navigate focus. Checked by the run loop.
    var handlesArrowKeys: Bool { false }

    /// Handles an arrow key when `handlesArrowKeys` is true. Returns whether it
    /// was consumed; returning false at a boundary (e.g. the cursor is already on
    /// the last line and moves down) lets focus navigation take over, so the user
    /// can still arrow out of the control.
    func handleArrowKey(_ direction: ArrowKeyDirection) -> Bool { false }

    /// Handles an editing command decoded from a modified key (Option/Ctrl/Cmd +
    /// arrow, Home/End, Option-Backspace, …). Returns whether it was consumed.
    func handleKeyCommand(_ command: KeyCommand) -> Bool { false }

    // MARK: - Scrolling

    func scroll(to position: Position) {
        parent?.scroll(to: position + layer.frame.position)
    }

}

/// A direction for arrow-key handling, shared by focus navigation and controls
/// that move a cursor.
enum ArrowKeyDirection {
    case up, down, left, right
}

/// An editing command decoded from a modified key press, delivered to whichever
/// control is focused (a text editor). Terminals encode these very differently,
/// so the run loop maps the many escape sequences onto this small set.
enum KeyCommand {
    case wordLeft, wordRight
    case lineStart, lineEnd
    case documentStart, documentEnd
    case deleteWordBackward
    case deleteToLineStart
    case deleteForward
}
