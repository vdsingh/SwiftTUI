import Foundation

public extension View {
    /// Makes the view respond to sideways mouse-wheel scrolling while the
    /// pointer is anywhere over it.
    ///
    /// `delta` is -1 for a leftward tick and +1 for a rightward one. The view
    /// stays out of keyboard focus and does not affect clicks or the vertical
    /// wheel; it has no effect without a mouse.
    func onHorizontalScroll(_ action: @escaping (_ delta: Int) -> Void) -> some View {
        OnHorizontalScroll(content: self, action: action)
    }
}

struct OnHorizontalScroll<Content: View>: View, PrimitiveView {
    let content: VStack<Content>
    let action: (Int) -> Void

    init(content: Content, action: @escaping (Int) -> Void) {
        self.content = VStack(content: content)
        self.action = action
    }

    static var size: Int? { Content.size }

    func buildNode(_ node: Node) {
        node.addNode(at: 0, Node(view: content.view))
        let control = OnHorizontalScrollControl(action: action)
        control.content = node.children[0].control(at: 0)
        control.addSubview(control.content, at: 0)
        node.control = control
    }

    func updateNode(_ node: Node) {
        node.view = self
        node.children[0].update(using: content.view)
        (node.control as? OnHorizontalScrollControl)?.action = action
    }

    private class OnHorizontalScrollControl: Control {
        var action: (Int) -> Void
        var content: Control!

        init(action: @escaping (Int) -> Void) {
            self.action = action
        }

        override func size(proposedSize: Size) -> Size {
            content.size(proposedSize: proposedSize)
        }

        override func layout(size: Size) {
            super.layout(size: size)
            content.layout(size: size)
        }

        override func handleHorizontalScroll(_ delta: Int) -> Bool {
            action(delta)
            return true
        }
    }
}
