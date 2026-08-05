import Foundation

public extension View {
    /// Lays the view over the rest of the interface at a fixed cell position,
    /// taking it out of the normal layout flow entirely: where it appears in
    /// the tree it occupies no space, so opening and closing it never shifts
    /// the layout around it. Its layer sits above the whole normal tree, which
    /// is what a dropdown or tooltip needs. The view joins neither keyboard
    /// focus nor mouse hit testing.
    func floating(column: Int, line: Int) -> some View {
        Floating(content: self, column: column, line: line)
    }
}

struct Floating<Content: View>: View, PrimitiveView {
    let content: VStack<Content>
    let column: Int
    let line: Int

    init(content: Content, column: Int, line: Int) {
        self.content = VStack(content: content)
        self.column = column
        self.line = line
    }

    static var size: Int? { 1 }

    func buildNode(_ node: Node) {
        node.addNode(at: 0, Node(view: content.view))
        let control = FloatingControl()
        control.content = node.children[0].control(at: 0)
        control.column = column
        control.line = line
        node.control = control
    }

    func updateNode(_ node: Node) {
        node.view = self
        node.children[0].update(using: content.view)
        if let control = node.control as? FloatingControl {
            control.column = column
            control.line = line
        }
    }

    private class FloatingControl: Control {
        /// The floated content. Deliberately not a subview: `addSubview` would
        /// nest its layer inside this zero-sized control's layer, where it
        /// could never be drawn. The node tree still owns and updates it.
        var content: Control!
        var column = 0
        var line = 0

        override func size(proposedSize: Size) -> Size {
            Size(width: 0, height: 0)
        }

        override func layout(size: Size) {
            super.layout(size: size)
            // The content layer lives directly on the root layer, above the
            // whole normal tree, and is placed in absolute coordinates. Its
            // frame changes invalidate exactly the cells it covered and
            // covers, so opening and closing stays a local repaint.
            if content.layer.parent == nil {
                var root = layer
                while let parent = root.parent { root = parent }
                guard root !== content.layer else { return }
                root.addLayer(content.layer, at: root.children.count)
            }
            let contentSize = content.size(proposedSize: Size(width: .infinity, height: .infinity))
            content.layer.frame = Rect(
                position: Position(column: Extended(column), line: Extended(line)),
                size: contentSize
            )
            content.layout(size: contentSize)
        }
    }
}
