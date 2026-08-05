import Foundation

public extension View {
    /// Makes the view respond to a mouse click without joining keyboard focus.
    ///
    /// Unlike `Button`, the result is not selectable: arrow-key navigation skips
    /// it and it never becomes the first responder, so it can sit ahead of the
    /// real controls (a title bar, a toolbar) without stealing the initial focus
    /// or swallowing typed input. It has no effect without a mouse.
    func onClick(_ action: @escaping () -> Void) -> some View {
        OnClick(content: self, action: action)
    }
}

struct OnClick<Content: View>: View, PrimitiveView {
    let content: VStack<Content>
    let action: () -> Void

    init(content: Content, action: @escaping () -> Void) {
        self.content = VStack(content: content)
        self.action = action
    }

    static var size: Int? { Content.size }

    func buildNode(_ node: Node) {
        node.addNode(at: 0, Node(view: content.view))
        let control = OnClickControl(action: action)
        control.content = node.children[0].control(at: 0)
        control.addSubview(control.content, at: 0)
        node.control = control
    }

    func updateNode(_ node: Node) {
        node.view = self
        node.children[0].update(using: content.view)
        (node.control as? OnClickControl)?.action = action
    }

    private class OnClickControl: Control {
        var action: () -> Void
        var content: Control!

        init(action: @escaping () -> Void) {
            self.action = action
        }

        override func size(proposedSize: Size) -> Size {
            content.size(proposedSize: proposedSize)
        }

        override func layout(size: Size) {
            super.layout(size: size)
            content.layout(size: size)
        }

        // Clickable, but not part of keyboard focus.
        override var selectable: Bool { false }
        override var clickable: Bool { true }

        override func activateByClick(at point: Position) {
            action()
        }
    }
}
