import CoreGraphics
import Foundation

/// Where a sidebar tab dragged over the workspace would land (#227). The
/// cursor picks a LEVEL in the split tree, not just a side of the hovered
/// pane, so one drag can produce a whole-edge pane, an equal sibling at a
/// divider, or a plain local split.
struct TabDropResolution: Equatable {
    enum Target: Equatable {
        /// Split the whole workspace on this side: the dropped tree becomes a
        /// new top-level sibling, equalized along that axis.
        case rootEdge(PaneDropZone)
        /// Insert beside this pane at its shared divider, equalizing the axis
        /// — the "side-by-side-by-side, thirds for all" outcome.
        case divider(UUID, PaneDropZone)
        /// Plain local split of this pane (halves it).
        case pane(UUID, PaneDropZone)
    }

    let target: Target
    /// Workspace-normalized rect the dropped tab would occupy — the drop
    /// preview highlights exactly this region, so the user sees the outcome
    /// before releasing.
    let preview: CGRect
}

/// Resolves a workspace-normalized cursor point against the split tree.
///
/// The rule of thumb is "drop where the new pane will appear":
/// - Within `boundaryBand` of a workspace edge that lies on the root split's
///   own axis → a new top-level sibling on that side (H(a,b) dropped far left
///   becomes thirds).
/// - Within `boundaryBand` of an internal divider → insert at that divider,
///   equalized (H(a,b) dropped in the middle becomes thirds).
/// - A side PERPENDICULAR to the root axis has no divider or edge band of its
///   own, so its root-level band sits just past the workspace midline — e.g.
///   with two columns, a whole-bottom pane is grabbed at "the top side of the
///   bottom half" (`0.5...perpendicularBandEnd`), while dragging deeper stays
///   a local split of the hovered pane.
/// - Anywhere else → the hovered pane's four-triangle zone, split locally.
///
/// Deep trees are handled by the same bands: only the ROOT's direction picks
/// same-axis vs perpendicular behavior, which keeps the rule predictable.
@MainActor
enum TabDropPlacer {
    /// Within this fraction of the workspace, an edge or divider captures the
    /// drop and escalates it past the hovered pane.
    static let boundaryBand: CGFloat = 0.15
    /// The far end of the perpendicular root band: between the midline and
    /// this coordinate the drop splits the whole workspace; past it the drop
    /// is local to the hovered pane. Kept slim (the same 15% the edge and
    /// divider bands get) so the LOCAL top/bottom split — dropping a tab as a
    /// horizontal strip inside one pane — keeps a comfortable margin.
    static let perpendicularBandEnd: CGFloat = 0.65

    static func resolve(point: CGPoint, in root: SplitNode) -> TabDropResolution? {
        // Clamp inside the unit square so an edge-exact drop still lands in a
        // pane (CGRect.contains excludes max edges).
        let p = CGPoint(x: min(max(point.x, 0), 0.9999), y: min(max(point.y, 0), 0.9999))
        let frames = root.paneFrames()
        guard let hovered = frames.first(where: { $0.value.contains(p) }) else { return nil }
        let (paneID, frame) = hovered
        let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        let zone = PaneDropZone.calculate(at: local, in: frame.size)

        guard case let .split(rootBranch) = root else {
            // A single pane: a root split IS the local split.
            return TabDropResolution(target: .pane(paneID, zone), preview: paneHalf(frame, zone))
        }

        let axis = zone.splitDirection
        let edge = edgeCoordinate(of: frame, zone: zone)
        let cursor = axis == .horizontal ? p.x : p.y
        let workspaceEdge: CGFloat = zone.splitPosition == .first ? 0 : 1
        let units = root.tileUnits(along: axis)
        let fraction = 1 / CGFloat(units + 1)

        if abs(edge - workspaceEdge) < 0.0001 {
            // The hovered pane's edge on this side IS the workspace boundary.
            if rootBranch.direction == axis {
                if abs(cursor - workspaceEdge) < boundaryBand {
                    return TabDropResolution(target: .rootEdge(zone), preview: edgeStrip(zone: zone, fraction: fraction))
                }
            } else {
                let inRootBand = zone.splitPosition == .second
                    ? (cursor >= 0.5 && cursor < perpendicularBandEnd)
                    : (cursor <= 0.5 && cursor > 1 - perpendicularBandEnd)
                if inRootBand {
                    return TabDropResolution(target: .rootEdge(zone), preview: edgeStrip(zone: zone, fraction: fraction))
                }
            }
        } else if abs(cursor - edge) < boundaryBand {
            // The pane's edge adjoins a sibling: insert at the divider.
            return TabDropResolution(
                target: .divider(paneID, zone),
                preview: dividerStrip(at: edge, fraction: fraction, crossing: frame, zone: zone)
            )
        }
        return TabDropResolution(target: .pane(paneID, zone), preview: paneHalf(frame, zone))
    }

    // MARK: - Geometry helpers

    private static func edgeCoordinate(of frame: CGRect, zone: PaneDropZone) -> CGFloat {
        switch zone {
        case .left: frame.minX
        case .right: frame.maxX
        case .top: frame.minY
        case .bottom: frame.maxY
        }
    }

    private static func paneHalf(_ frame: CGRect, _ zone: PaneDropZone) -> CGRect {
        switch zone {
        case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }

    private static func edgeStrip(zone: PaneDropZone, fraction: CGFloat) -> CGRect {
        switch zone {
        case .left: CGRect(x: 0, y: 0, width: fraction, height: 1)
        case .right: CGRect(x: 1 - fraction, y: 0, width: fraction, height: 1)
        case .top: CGRect(x: 0, y: 0, width: 1, height: fraction)
        case .bottom: CGRect(x: 0, y: 1 - fraction, width: 1, height: fraction)
        }
    }

    /// A strip centered on the divider, spanning the hovered pane's extent on
    /// the cross axis (so a nested divider previews within its own column).
    private static func dividerStrip(at edge: CGFloat, fraction: CGFloat, crossing frame: CGRect, zone: PaneDropZone) -> CGRect {
        let start = min(max(edge - fraction / 2, 0), 1 - fraction)
        return switch zone.splitDirection {
        case .horizontal: CGRect(x: start, y: frame.minY, width: fraction, height: frame.height)
        case .vertical: CGRect(x: frame.minX, y: start, width: frame.width, height: fraction)
        }
    }
}
