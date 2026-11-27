import SwiftUI

/// A single line of capsules that scrolls sideways when it does not fit,
/// centred when it does, with the edges fading only where more is hidden.
struct CapsuleScrollRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    var inset: CGFloat = 18
    var spacing: CGFloat = 8
    var fadeWidth: CGFloat = Theme.Space.xxl
    /// Whether the row scrolls. Production does; a snapshot passes `false`
    /// because `ImageRenderer` cannot draw a `ScrollView`, and the capsules are
    /// the part worth pinning -- the same stopgap as `CommandSkillPaletteView`.
    var scrolls = true
    @ViewBuilder var content: (Item) -> Content

    @State private var rowWidth: CGFloat = 0
    @State private var edges = HiddenEdges()

    var body: some View {
        if scrolls {
            scrollingRow
        } else {
            // The same capsules and the same paddings, without the UIKit
            // container the renderer cannot draw.
            row
        }
    }

    private var row: some View {
        HStack(spacing: spacing) {
            ForEach(items) { item in
                content(item)
                    .fixedSize()
                    .id(item.id)
            }
        }
        .padding(.horizontal, inset)
        // Room for the glass's own shadow, which a scroll view clips.
        .padding(.vertical, 6)
        .frame(minWidth: rowWidth, alignment: .center)
    }

    private var scrollingRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                row
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .onScrollGeometryChange(for: HiddenEdges.self) { geometry in
                HiddenEdges(
                    leading: geometry.contentOffset.x > 0.5,
                    trailing: geometry.contentOffset.x + geometry.containerSize.width
                        < geometry.contentSize.width - 0.5,
                )
            } action: { _, next in
                withMizarAnimation(.mizarSnappy) { edges = next }
            }
            .mask { EdgeFadeMask(leading: edges.leading, trailing: edges.trailing, width: fadeWidth) }
            .padding(.vertical, -6)
            .onChange(of: items.map(\.id)) { old, new in
                guard new.count > old.count, let last = new.last else { return }
                withMizarAnimation(.mizarSmooth) { proxy.scrollTo(last, anchor: .trailing) }
            }
        }
    }
}

private struct HiddenEdges: Equatable {
    var leading = false
    var trailing = false
}

/// Opaque in the middle; at each edge a gradient that a black layer covers
/// while nothing is hidden on that side. Opacity, not gradient stops, is
/// what animates.
private struct EdgeFadeMask: View {
    let leading: Bool
    let trailing: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                Color.black.opacity(leading ? 0 : 1)
            }
            .frame(width: width)
            Color.black
            ZStack {
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                Color.black.opacity(trailing ? 0 : 1)
            }
            .frame(width: width)
        }
    }
}
