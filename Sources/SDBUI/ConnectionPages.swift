import Foundation
@_spi(Backends) import SwiftCrossUI

/// Retains each session's view graph and native widgets. Only the selected page
/// is attached to the container, so inactive pages neither take space nor accept
/// input. Removing a tab releases its graph; switching tabs does not rebuild it.
struct ConnectionPages: View {
    var tabs: [ConnectionWorkspace.Tab]
    var selectedID: UUID

    var body = EmptyView()

    func children<Backend: BaseAppBackend>(
        backend: Backend,
        snapshots: [ViewGraphSnapshotter.NodeSnapshot]?,
        environment: EnvironmentValues
    ) -> any ViewGraphNodeChildren {
        ConnectionPageChildren()
    }

    func layoutableChildren<Backend: BaseAppBackend>(
        backend: Backend,
        children: any ViewGraphNodeChildren
    ) -> [LayoutSystem.LayoutableChild] { [] }

    func asWidget<Backend: BaseAppBackend>(
        _ children: any ViewGraphNodeChildren,
        backend: Backend
    ) -> Backend.Widget {
        backend.createContainer()
    }

    func computeLayout<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: any ViewGraphNodeChildren,
        proposedSize: ProposedViewSize,
        environment: EnvironmentValues,
        backend: Backend
    ) -> ViewLayoutResult {
        let pages = children as! ConnectionPageChildren
        let liveIDs = Set(tabs.map(\.id))
        // Unparent before releasing a closed page's widget.
        if pages.attachedID != selectedID {
            backend.removeAllChildren(of: widget)
            pages.attachedID = nil
        }
        pages.nodes = pages.nodes.filter { liveIDs.contains($0.key) }
        pages.presentations = pages.presentations.filter { liveIDs.contains($0.key) }
        let size = proposedSize.replacingUnspecifiedDimensions(by: ViewSize(10, 10))
        guard let tab = tabs.first(where: { $0.id == selectedID }) else {
            return ViewLayoutResult(size: size, childResults: [])
        }
        let node: AnyViewGraphNode<RootView>
        if let cached = pages.nodes[selectedID] {
            node = cached
        } else {
            node = AnyViewGraphNode(for: RootView(model: tab.model), backend: backend, environment: environment)
            pages.nodes[selectedID] = node
        }
        if pages.attachedID == nil {
            backend.insert(node.widget.into(), into: widget, at: 0)
            pages.attachedID = selectedID
        }
        let presentation = ConnectionPageChildren.Presentation(environment)
        let concrete = node.concreteNode(for: Backend.self)
        let result: ViewLayoutResult
        if !pages.needsCommit, node.lastProposedSize == ProposedViewSize(size),
           pages.presentations[selectedID] == presentation, let current = concrete.currentLayout {
            // Child observations already keep the cached page current. Switching
            // at the same size needs neither a layout traversal nor native updates.
            result = current
        } else {
            result = node.computeLayout(with: nil, proposedSize: ProposedViewSize(size), environment: environment)
            pages.presentations[selectedID] = presentation
            pages.needsCommit = true
        }
        return ViewLayoutResult(size: size, childResults: [result])
    }

    func commit<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: any ViewGraphNodeChildren,
        layout: ViewLayoutResult,
        environment: EnvironmentValues,
        backend: Backend
    ) {
        let pages = children as! ConnectionPageChildren
        if let id = pages.attachedID, let node = pages.nodes[id] {
            if pages.needsCommit {
                _ = node.commit()
                pages.needsCommit = false
            }
            backend.setPosition(ofChildAt: 0, in: widget, to: .zero)
        }
        backend.setSize(of: widget, to: layout.size.vector)

    }
}

@MainActor
private final class ConnectionPageChildren: ViewGraphNodeChildren {
    var nodes: [UUID: AnyViewGraphNode<RootView>] = [:]
    var attachedID: UUID?
    var needsCommit = false
    var presentations: [UUID: Presentation] = [:]

    struct Presentation: Equatable {
        let colorScheme: ColorScheme
        let font: Font.Resolved
        let scale: Double
        let enabled: Bool

        @MainActor init(_ environment: EnvironmentValues) {
            colorScheme = environment.colorScheme
            font = environment.resolvedFont
            scale = environment.windowScaleFactor
            enabled = environment.isEnabled
        }
    }

    var widgets: [AnyWidget] {
        attachedID.flatMap { nodes[$0]?.widget }.map { [$0] } ?? []
    }
    var erasedNodes: [ErasedViewGraphNode] {
        nodes.values.map { ErasedViewGraphNode(wrapping: $0) }
    }
}
