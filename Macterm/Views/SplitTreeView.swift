import AppKit
import SwiftUI

/// Recursively renders a split tree as nested split views or a single terminal pane.
struct SplitTreeView: View {
    let node: SplitNode
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?
    let isActiveProject: Bool
    let projectID: UUID
    let isSplit: Bool
    let onFocusPane: (UUID) -> Void
    let onSplit: (UUID, SplitDirection) -> Void
    let onClosePane: (UUID) -> Void
    let onCommandFinished: (UUID) -> Void
    let onAdaptiveBackgroundChange: (UUID, CGColor?) -> Void
    let onToggleZoom: (UUID) -> Void
    /// When present, each leaf (except the dragged pane's own) becomes a drop
    /// target for grab-handle pane drags, reporting into the shared workspace
    /// resolution (see `PaneDropContext`).
    let paneDrop: PaneDropContext?

    init(
        node: SplitNode,
        focusedPaneID: UUID?,
        zoomedPaneID: UUID? = nil,
        isActiveProject: Bool,
        projectID: UUID,
        isSplit: Bool = false,
        onFocusPane: @escaping (UUID) -> Void,
        onSplit: @escaping (UUID, SplitDirection) -> Void,
        onClosePane: @escaping (UUID) -> Void,
        onCommandFinished: @escaping (UUID) -> Void = { _ in },
        onAdaptiveBackgroundChange: @escaping (UUID, CGColor?) -> Void = { _, _ in },
        onToggleZoom: @escaping (UUID) -> Void = { _ in },
        paneDrop: PaneDropContext? = nil
    ) {
        self.node = node
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
        self.isActiveProject = isActiveProject
        self.projectID = projectID
        self.isSplit = isSplit
        self.onFocusPane = onFocusPane
        self.onSplit = onSplit
        self.onClosePane = onClosePane
        self.onCommandFinished = onCommandFinished
        self.onAdaptiveBackgroundChange = onAdaptiveBackgroundChange
        self.onToggleZoom = onToggleZoom
        self.paneDrop = paneDrop
    }

    var body: some View {
        switch node {
        case let .pane(pane):
            SplitLeafView(
                pane: pane,
                isFocused: focusedPaneID == pane.id && isActiveProject,
                isZoomed: zoomedPaneID == pane.id,
                isSplit: isSplit,
                onFocus: { onFocusPane(pane.id) },
                onProcessExit: { onClosePane(pane.id) },
                onCommandFinished: { onCommandFinished(pane.id) },
                onAdaptiveBackgroundChange: { onAdaptiveBackgroundChange(pane.id, $0) },
                onSplitRequest: { dir in onSplit(pane.id, dir) },
                onZoomRequest: { onToggleZoom(pane.id) },
                paneDrop: paneDrop
            )

        case let .split(branch):
            SplitDividerView(branch: branch) {
                SplitTreeView(
                    node: branch.first,
                    focusedPaneID: focusedPaneID,
                    zoomedPaneID: zoomedPaneID,
                    isActiveProject: isActiveProject,
                    projectID: projectID,
                    isSplit: true,
                    onFocusPane: onFocusPane,
                    onSplit: onSplit,
                    onClosePane: onClosePane,
                    onCommandFinished: onCommandFinished,
                    onAdaptiveBackgroundChange: onAdaptiveBackgroundChange,
                    onToggleZoom: onToggleZoom,
                    paneDrop: paneDrop
                )
                .id(branch.first.id)
            } second: {
                SplitTreeView(
                    node: branch.second,
                    focusedPaneID: focusedPaneID,
                    zoomedPaneID: zoomedPaneID,
                    isActiveProject: isActiveProject,
                    projectID: projectID,
                    isSplit: true,
                    onFocusPane: onFocusPane,
                    onSplit: onSplit,
                    onClosePane: onClosePane,
                    onCommandFinished: onCommandFinished,
                    onAdaptiveBackgroundChange: onAdaptiveBackgroundChange,
                    onToggleZoom: onToggleZoom,
                    paneDrop: paneDrop
                )
                .id(branch.second.id)
            }
        }
    }
}

/// One leaf of the split tree: the terminal pane plus the grab handle that
/// starts a pane drag and the leaf's own pane-drop capture, which reports
/// into the shared workspace resolution (see `PaneDropContext`).
private struct SplitLeafView: View {
    let pane: Pane
    let isFocused: Bool
    let isZoomed: Bool
    let isSplit: Bool
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onCommandFinished: () -> Void
    let onAdaptiveBackgroundChange: (CGColor?) -> Void
    let onSplitRequest: (SplitDirection) -> Void
    let onZoomRequest: () -> Void
    let paneDrop: PaneDropContext?

    var body: some View {
        TerminalPane(
            pane: pane,
            focused: isFocused,
            isZoomed: isZoomed,
            onFocus: onFocus,
            onProcessExit: onProcessExit,
            onCommandFinished: onCommandFinished,
            onAdaptiveBackgroundChange: onAdaptiveBackgroundChange,
            onSplitRequest: { dir, _ in onSplitRequest(dir) },
            onZoomRequest: onZoomRequest
        )
        .overlay {
            if !isFocused, isSplit, pane.adaptiveBackgroundColor == nil {
                // Theme-derived dim (not fixed black) so an unfocused pane
                // dims correctly on light themes too, at the user-configured
                // opacity (#156). A pane whose TUI supplies its own adaptive
                // background stays color-accurate even while unfocused.
                MactermTheme.dimOverlay(opacity: Preferences.shared.paneDimOpacity)
                    .allowsHitTesting(false)
            }
        }
        .background {
            // Pane-drag drop capture, one target per leaf: AppKit only fires
            // dragging-entered on a transition INTO a destination, so a
            // whole-workspace target never hears about a drag that started
            // inside it. The dragged pane's own leaf carries no target.
            if let paneDrop, paneDrop.draggedPaneID != pane.id {
                GeometryReader { geo in
                    Color.clear.onDrop(of: paneDrop.acceptedTypes, delegate: LeafDropDelegate(
                        context: paneDrop,
                        paneID: pane.id,
                        viewSize: geo.size
                    ))
                }
            }
        }
        .overlay {
            // Dragging the only pane of a tab has nowhere to go — the
            // handle only exists once the tab is split.
            if isSplit {
                PaneGrabHandle(pane: pane)
            }
        }
    }
}

/// A resizable split container with a draggable divider.
struct SplitDividerView<First: View, Second: View>: View {
    let branch: SplitBranch
    @ViewBuilder
    let first: First
    @ViewBuilder
    let second: Second
    /// Tracks whether the resize cursor is currently pushed, so it can be
    /// popped on disappear. SwiftUI does not deliver `onHover(false)` when the
    /// divider leaves the hierarchy mid-hover (pane close, zoom toggle, tab
    /// switch), which would otherwise leave the resize cursor stuck on the
    /// global cursor stack.
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let h = branch.direction == .horizontal
            let total = h ? geo.size.width : geo.size.height
            let firstSize = max(0, total * branch.ratio - 0.5)
            let secondSize = max(0, total * (1 - branch.ratio) - 0.5)
            let layout = h ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))

            layout {
                first.frame(width: h ? firstSize : nil, height: h ? nil : firstSize)

                Color.clear
                    .frame(width: h ? 1 : nil, height: h ? nil : 1)
                    .overlay(Rectangle().fill(MactermTheme.border))
                    .overlay {
                        Color.clear
                            .frame(width: h ? 5 : nil, height: h ? nil : 5)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                                let pos = h ? v.location.x : v.location.y
                                let origin = h ? v.startLocation.x : v.startLocation.y
                                let newPos = total * branch.ratio + (pos - origin)
                                branch.ratio = min(max(newPos / total, 0.15), 0.85)
                            })
                            .onHover { on in
                                if on {
                                    (h ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                                    isHovering = true
                                } else {
                                    NSCursor.pop()
                                    isHovering = false
                                }
                            }
                            // Balance a push that never got its hover-exit pop
                            // (divider removed mid-hover). Gated on `isHovering`
                            // so a non-hovered divider doesn't over-pop.
                            .onDisappear {
                                if isHovering {
                                    NSCursor.pop()
                                    isHovering = false
                                }
                            }
                    }

                second.frame(width: h ? secondSize : nil, height: h ? nil : secondSize)
            }
        }
    }
}
