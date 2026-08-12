import Foundation
@testable import Macterm
import Testing

/// Pins the "globality" bands from #227: where the cursor sits over the
/// workspace decides the LEVEL of the split a dropped tab produces, not just
/// the side. The scenarios mirror the issue discussion's two-columns
/// examples.
@MainActor
struct TabDropPlacementTests {
    private func twoColumns() -> (SplitNode, [String: UUID]) {
        build(H(pane("a"), pane("b")))
    }

    // MARK: - Same-axis bands (side-by-side-by-side)

    @Test
    func far_out_at_the_workspace_edge_targets_the_root() throws {
        let (root, _) = twoColumns()
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.05, y: 0.5), in: root))
        #expect(r.target == .rootEdge(.left))
        // Preview shows the even third the new column will take.
        #expect(abs(r.preview.width - 1.0 / 3.0) < 0.001)
        #expect(abs(r.preview.minX) < 0.001)
        #expect(abs(r.preview.height - 1) < 0.001)
    }

    @Test
    func between_edge_and_middle_splits_the_pane_locally() throws {
        let (root, ids) = twoColumns()
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.2, y: 0.5), in: root))
        #expect(try r.target == .pane(#require(ids["a"]), .left))
        // Preview is the pane's half: the 1/4 1/4 1/2 outcome.
        #expect(abs(r.preview.width - 0.25) < 0.001)
    }

    @Test
    func the_middle_targets_the_divider() throws {
        let (root, ids) = twoColumns()
        let left = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.45, y: 0.5), in: root))
        #expect(try left.target == .divider(#require(ids["a"]), .right))
        let right = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.55, y: 0.5), in: root))
        #expect(try right.target == .divider(#require(ids["b"]), .left))
        // Both previews are the same middle third straddling the divider.
        #expect(abs(left.preview.midX - 0.5) < 0.001)
        #expect(abs(left.preview.width - 1.0 / 3.0) < 0.001)
        #expect(left.preview == right.preview)
    }

    // MARK: - Perpendicular bands (whole bottom pane)

    @Test
    func just_past_the_midline_targets_the_whole_bottom() throws {
        let (root, _) = twoColumns()
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.25, y: 0.6), in: root))
        #expect(r.target == .rootEdge(.bottom))
        // Preview: the full-width bottom half.
        #expect(abs(r.preview.width - 1) < 0.001)
        #expect(abs(r.preview.height - 0.5) < 0.001)
        #expect(abs(r.preview.minY - 0.5) < 0.001)
    }

    @Test
    func past_the_global_band_the_local_split_takes_over() throws {
        let (root, ids) = twoColumns()
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.25, y: 0.8), in: root))
        #expect(try r.target == .pane(#require(ids["a"]), .bottom))
    }

    @Test
    func side_by_side_margins_span_the_full_height() throws {
        // The root-axis edge and divider bands are NOT gated by the corner
        // triangles: a drop near the workspace edge or a divider reads as
        // side-by-side at any height, even deep in a pane's bottom corner.
        let (root, ids) = twoColumns()
        let atEdge = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.05, y: 0.9), in: root))
        #expect(atEdge.target == .rootEdge(.left))
        let atDivider = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.45, y: 0.9), in: root))
        #expect(try atDivider.target == .divider(#require(ids["a"]), .right))
    }

    @Test
    func deep_in_a_pane_splits_that_pane_down() throws {
        let (root, ids) = twoColumns()
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.25, y: 0.9), in: root))
        #expect(try r.target == .pane(#require(ids["a"]), .bottom))
        // Preview: that pane's bottom half only.
        #expect(abs(r.preview.width - 0.5) < 0.001)
        #expect(abs(r.preview.height - 0.5) < 0.001)
    }

    @Test
    func the_top_band_mirrors_the_bottom() throws {
        let (root, _) = twoColumns()
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.75, y: 0.4), in: root))
        #expect(r.target == .rootEdge(.top))
    }

    // MARK: - Skinny panes (band cap)

    /// Four equal columns; without the per-pane band cap the fixed 0.15
    /// workspace bands swallow every pixel of every 0.25-wide pane and no
    /// top/bottom placement is reachable at all.
    private func fourColumns() -> (SplitNode, [String: UUID]) {
        build(H(pane("a"), H(pane("b"), H(pane("c"), pane("d"), ratio: 0.5), ratio: 1.0 / 3.0), ratio: 0.25))
    }

    @Test
    func skinny_pane_can_still_take_the_whole_bottom() throws {
        let (root, _) = fourColumns()
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.125, y: 0.6), in: root))
        #expect(r.target == .rootEdge(.bottom))
    }

    @Test
    func skinny_pane_can_still_split_top_down_locally() throws {
        let (root, ids) = fourColumns()
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.125, y: 0.9), in: root))
        #expect(try r.target == .pane(#require(ids["a"]), .bottom))
    }

    @Test
    func skinny_pane_keeps_proportional_edge_and_divider_bands() throws {
        let (root, ids) = fourColumns()
        // Bands shrink to 0.3 × 0.25 = 0.075 of the workspace.
        let edge = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.05, y: 0.5), in: root))
        #expect(edge.target == .rootEdge(.left))
        let divider = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.24, y: 0.5), in: root))
        #expect(try divider.target == .divider(#require(ids["a"]), .right))
        // The middle of the pane stays out of both bands.
        let mid = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.1, y: 0.5), in: root))
        #expect(try mid.target == .pane(#require(ids["a"]), .left))
    }

    // MARK: - Structure edge cases

    @Test
    func single_pane_root_is_always_a_local_split() throws {
        let (root, ids) = build(pane("a"))
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.02, y: 0.5), in: root))
        #expect(try r.target == .pane(#require(ids["a"]), .left))
    }

    @Test
    func nested_divider_resolves_within_its_column() throws {
        // Right column split vertically; hover near ITS internal divider.
        let (root, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.75, y: 0.45), in: root))
        #expect(try r.target == .divider(#require(ids["b"]), .bottom))
        // Preview stays inside the right column.
        #expect(abs(r.preview.minX - 0.5) < 0.001)
        #expect(abs(r.preview.width - 0.5) < 0.001)
    }
}
